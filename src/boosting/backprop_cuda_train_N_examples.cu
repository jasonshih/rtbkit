#define FOR_ALL_X(expr) \
    for (int x = 0;  x < N;  ++x) expr;

__device__ void
train_N_examples(const float * input,
                 const int *labels,
                 const float * example_weights,
                 int valid_examples,
                 int num_layers,
                 float * scratch,  // shared memory scratch space
#if defined(__DEVICE_EMULATION__)
                 const float * w,
                 const float * biases,
#else
                 const WeightsAccess<weights_tex> & w,
                 const WeightsAccess<biases_tex> & biases,
#endif
                 const int * architecture,
                 const int * w_strides,
                 UpdateFloat * const * w_updates, // wt updates for each layer
                 UpdateFloat * const * b_updates, // bias upd for each layer
                 int activation,            // activation function
                 float fire,   // target value for firing neuron
                 float inhibit, // target value for inhibited neuron)
                 float learning_rate,
                 int num_threads_in_block,
                 int num_threads_on_multiprocessor,
                 int total_neurons,
                 int max_width,
                 float * layer_outputs)  // global scratch space[total neurons]
{
    // access thread id
    const unsigned tid = threadIdx.x;

    const unsigned block_num  = blockIdx.x;


    /*************************************************************************/
    /* FPROP                                                                 */
    /*************************************************************************/

    /* First, copy the inputs into shared memory */
    int ni = architecture[0], no, w_stride;

    int input_stride = ni;
    int scratch_stride = max_width;
    
    for (int x = 0;  x < N;  ++x) {
#if defined(__DEVICE_EMULATION__) && 0
        fprintf(stderr, "tid %d block_num %d scratch_stride %d x %d\n",
                tid, block_num, scratch_stride, x);
#endif
        scratch[x * scratch_stride + tid]
            = (tid < ni ? input[x * input_stride + tid] : 0.0);
    }

    /* Let everything catch up */
    __syncthreads();

    float * this_layer_outputs = layer_outputs;

#if defined(__DEVICE_EMULATION__)
    const float * layer_weights = w;
    const float * layer_biases = biases;
#else
    WeightsAccess<weights_tex> layer_weights = w;
    WeightsAccess<biases_tex> layer_biases  = biases;
#endif

    for (unsigned l = 0;
         l < num_layers;
         ++l,
             __syncthreads(),
             layer_weights += ni * w_stride,
             layer_biases += no,
             this_layer_outputs += no) {

        // Get architecture information about the layer:
        ni = architecture[l];
        no = architecture[l + 1];
        w_stride = w_strides[l];

        /* We want to have each thread working here, even if no is much less
           than the number of threads.  To do so, we assign each thread to
           a certain o value and a certain subset of the i values, and then
           accumulate the updates, broadcasting them at the end.

           For example:
           32 threads
           2 outputs

           So we have 16 threads working on each example

           100 threads
           16 outputs

           So we have 7 threads on the first 4 examples, and 6 threads on
           the rest.
        */

        int nt = num_threads_on_multiprocessor;

        int min_threads = nt / no;
        int left_over   = nt % no;
        int max_threads = min_threads + (left_over > 0);

        int o = tid % no;    // which o value are we working on?
        int idx = tid / no;  // which thread in that block?
        int o_threads = min_threads + (o < left_over);

        //double * accum = (double *)(scratch + N * scratch_stride);
        double accum[N];

        FOR_ALL_X(accum[x] = 0.0);
        
        for (unsigned i = idx;  i < ni;  i += o_threads) {
            float weight = layer_weights[i * w_stride + o];
            FOR_ALL_X(accum[x] += weight * scratch[x * scratch_stride + i]);
        }

        if (max_threads > 1) {
            // Multiple threads working per entry; we need to synchronize

            __syncthreads();

            if (tid < no) {
                float bias = layer_biases[tid];
                FOR_ALL_X(scratch[x * scratch_stride + tid] = bias);
            }
            
            __syncthreads();
            
            /* Now we accumulate them, allowing each thread to increment in its
               turn. */
            for (unsigned i = 0;  i < max_threads;  ++i, __syncthreads())

                if (i == idx)
                    FOR_ALL_X(scratch[x * scratch_stride + o] += accum[x]);
            
            if (__any(tid < no)) {
                
                if (tid < no)
                    for (int x = 0;  x < N;  ++x)
                        this_layer_outputs[x * total_neurons + tid]
                            = scratch[x * scratch_stride + tid]
                            = transform(scratch[x * scratch_stride + tid],
                                        activation);
            }
        }
        else {
            // A single thread per entry; no synchronization
            float bias = layer_biases[o];

            for (int x = 0;  x < N;  ++x) {
                accum[x] += bias;
                this_layer_outputs[x * total_neurons + o]
                    = scratch[x * scratch_stride + o]
                    = transform(accum[x], activation);
            }
        }
    }

    // layer_biases is no longer used

    /*************************************************************************/
    /* BPROP                                                                 */
    /*************************************************************************/

    /* How many output layers? */
    this_layer_outputs -= no;

    layer_weights -= ni * w_stride;

    /* First error calculation pass */
    float last_output[N];
    FOR_ALL_X(last_output[x] = scratch[x * scratch_stride + tid]);

    __syncthreads();

    for (int x = 0;  x < N;  ++x) {
        bool correct = (labels[x] == tid);
        float wanted = (correct ? fire : inhibit);
        scratch[x * scratch_stride + tid]
            = (tid < no ? wanted - last_output[x] : 0.0);
    }
    
    /* Let everything catch up */
    __syncthreads();

    /* Backpropegate. */
    for (int l = num_layers - 1;  l >= 0;
         --l,
             __syncthreads(),
             layer_weights -= (l == -1 ? 0 : architecture[l] * w_strides[l]),
             this_layer_outputs -= architecture[l + 1]) {
        
        // Get information about the layer:
        ni = architecture[l];
        no = architecture[l + 1];
        w_stride = w_strides[l];

        UpdateFloat * layer_updates = w_updates[l];
        UpdateFloat * layer_bias_updates  = b_updates[l];
        
        const float * last_layer_outputs = this_layer_outputs - ni;

        //float * d = (scratch + N * scratch_stride);
        float d[N];

        for (int x = 0;  x < N;  ++x) {
            float prev_output
                = (tid >= no
                   ? 0.0
                   : this_layer_outputs[x * total_neurons + tid]);
            
            float error = scratch[x * scratch_stride + tid];
        
            d[x] = (tid >= no ? 0.0 : delta(prev_output, error, activation));
        }
        
        if (l > 0) {
            // Make sure all threads have caught up so that we can modify error
            // without affecting them
            __syncthreads();

            // Broadcast the d values so that we can use them to calculate the
            // errors

            for (int x = 0;  x < N;  ++x)
                scratch[x * scratch_stride + tid] = d[x];
            
            // Make sure everything can get its d value
            __syncthreads();
            
            double total[N];
            FOR_ALL_X(total[x] = 0.0);

            if (tid < ni) {
                for (unsigned o = 0;  o < no;  ++o) {
                    float w = layer_weights[tid * w_stride + o];
                    
                    for (int x = 0;  x < N;  ++x) {
                        float d = scratch[x * scratch_stride + o];
                        float update = d * w;
                        total[x] += update;
                    }
                }
            }

            // Wait for everything to finish so that we can overwrite the d
            // values with the new errors
            __syncthreads();
            
            for (int x = 0;  x < N;  ++x)
                scratch[x * scratch_stride + tid] = total[x];
        }

        // Again, threads indexed too low just leave
        if (tid >= no) continue;
        
        /* Update the weights. */
        float k[N];
        FOR_ALL_X(k[x] = (x < valid_examples) * example_weights[x] * learning_rate);

        /* Now for the updates.  In order to avoid trying to write the same
           memory over and over, we stagger the starting points so that
           each example will start at a different place, thus minimising
           conflicting writes when we have multiple multiprocessors working
           on the same thing. */

        int thread_stride = ni / num_threads_in_block;
        if (thread_stride == 0) thread_stride = 1;

        int start_at = (block_num * thread_stride) % ni;

        for (unsigned i_ = start_at;  i_ < ni + start_at;  ++i_) {

            // Get the real index of i
            unsigned i = i_ - (i_ >= ni) * ni;

            double total_update = 0.0;

            for (int x = 0;  x < N;  ++x) {
                float prev
                    = (l == 0
                       ? input[x * input_stride + i]
                       : last_layer_outputs[x * total_neurons + i]); 
                float update = prev * k[x] * d[x];
                total_update += update;
            }
            
            atomic_add(layer_updates[i * w_stride + tid], total_update);
        }
        
        /* Update the bias */
        double total_update = 0.0;
        FOR_ALL_X(total_update += k[x] * d[x]);

        //layer_bias_updates[tid] += update;
        atomic_add(layer_bias_updates[tid], total_update);
    }
}

