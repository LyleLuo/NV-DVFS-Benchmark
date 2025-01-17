

// includes, system
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <math.h>
#include <cuda.h>
#include <time.h>

#include <cuda_runtime.h>

#include <helper_functions.h>
#include <helper_cuda.h>

// includes, kernels
#include "backprop_cuda_kernel.cu"
#include "backprop.h"

int nIter = 100;
int secs = 180;
bool timeRestrict = false;

////////////////////////////////////////////////////////////////////////////////

extern "C"
void bpnn_layerforward(float *l1, float *l2, float **conn, int n1, int n2);

extern "C"
void bpnn_output_error(float *delta, float *target, float *output, int nj, float *err);

extern "C"
void bpnn_hidden_error(float *delta_h, int nh, float *delta_o, int no, float **who, float *hidden, float *err);

extern "C" 
void bpnn_adjust_weights(float *delta, int ndelta, float *ly, int nly, float **w, float **oldw);


extern "C"
int setup(int argc, char** argv);

extern "C"
float **alloc_2d_dbl(int m, int n);

extern "C"
float squash(float x);

double gettime() {
	time_t t;
	t = clock();
	return t*1e-3;
}

unsigned int num_threads = 0;
unsigned int num_blocks = 0;

////////////////////////////////////////////////////////////////////////////////
// Program main
////////////////////////////////////////////////////////////////////////////////
int
main( int argc, char** argv) 
{
	findCudaDevice(argc, (const char **)argv);

	// Iteration count
	if (checkCmdLineFlag(argc, (const char **)argv, "iters"))
	{
		nIter = getCmdLineArgumentInt(argc, (const char **)argv, "iters");
	}

	// Power Running Time
	if (checkCmdLineFlag(argc, (const char **)argv, "secs"))
	{
		secs = getCmdLineArgumentInt(argc, (const char **)argv, "secs");
		timeRestrict = true;
	}

	setup(argc, argv);
}


extern "C"
void bpnn_train_cuda(BPNN *net, float *eo, float *eh)
{
  int in, hid, out;
  float out_err, hid_err;
  
  in = net->input_n;
  hid = net->hidden_n;
  out = net->output_n;   
  
  //float gpuTime_1, gpuTime_2;
  ///* Time recording with cuda helper*/

  StopWatchInterface *hTimer = NULL;
  sdkCreateTimer(&hTimer);
  double totalTime = 0.0;
  int c = 0;
  double averMsecs = 0.0;

#ifdef GPU  
  int m = 0;
  float *input_hidden_cuda;
  float *input_cuda;
  float *output_hidden_cuda;
  float *partial_sum;
  float *hidden_partial_sum;
  float *hidden_delta_cuda;
  float *input_prev_weights_cuda;
  float sum;
  float *input_weights_one_dim;
  float *input_weights_prev_one_dim;
  num_blocks = in / 16;  
  dim3  grid( 1 , num_blocks);
  dim3  threads(16 , 16);
  
  input_weights_one_dim = (float *) malloc((in + 1)* (hid + 1) * sizeof(float));
  input_weights_prev_one_dim = (float *) malloc((in + 1)* (hid + 1) * sizeof(float));
  partial_sum = (float *) malloc(num_blocks * WIDTH * sizeof(float));
 
  // this preprocessing stage is added to correct the bugs of wrong memcopy using two-dimensional net->inputweights
  for (int k = 0; k <= in; k++) {	
   for (int j = 0; j <= hid; j++) {
	  input_weights_one_dim[m] = net->input_weights[k][j];
	  input_weights_prev_one_dim[m] = net-> input_prev_weights[k][j];
	  m++;
    }
  }
  
  cudaMalloc((void**) &input_cuda, (in + 1) * sizeof(float));
  cudaMalloc((void**) &output_hidden_cuda, (hid + 1) * sizeof(float));
  cudaMalloc((void**) &input_hidden_cuda, (in + 1) * (hid + 1) * sizeof(float));
  cudaMalloc((void**) &hidden_partial_sum, num_blocks * WIDTH * sizeof(float));
  
  
#endif

#ifdef CPU

  printf("Performing CPU computation\n");
  bpnn_layerforward(net->input_units, net->hidden_units,net->input_weights, in, hid);

#endif

#ifdef GPU
 
  printf("Performing GPU computation\n");

  cudaMemcpy(input_cuda, net->input_units, (in + 1) * sizeof(float), cudaMemcpyHostToDevice);
  cudaMemcpy(input_hidden_cuda, input_weights_one_dim, (in + 1) * (hid + 1) * sizeof(float), cudaMemcpyHostToDevice);

  //printf("in= %d, hid = %d, numblocks = %d\n", in, hid, num_blocks);
  totalTime = 0;
  averMsecs = 0;
  c = 0;

  for (int i = -20; i < nIter; i++){

	  cudaEvent_t start, stop;
	  // Record the start event
	  checkCudaErrors(cudaEventCreate(&start));
	  checkCudaErrors(cudaEventCreate(&stop));


	  // Run kernel and record the time
	  checkCudaErrors(cudaEventRecord(start, NULL));

	  bpnn_layerforward_CUDA << < grid, threads >> >(input_cuda,
		  output_hidden_cuda,
		  input_hidden_cuda,
		  hidden_partial_sum,
		  in,
		  hid);

	  cudaDeviceSynchronize();

	  cudaError_t error = cudaGetLastError();
	  if (error != cudaSuccess) {
		  printf("bpnn kernel error: %s\n", cudaGetErrorString(error));
		  exit(EXIT_FAILURE);
	  }

	  checkCudaErrors(cudaEventRecord(stop, NULL));

	  // Wait for the stop event to complete
	  checkCudaErrors(cudaEventSynchronize(stop));
	  float msecCurIter = 0.0f;
	  checkCudaErrors(cudaEventElapsedTime(&msecCurIter, start, stop));

	  totalTime += msecCurIter;
	  c++;
	  //iter == -1 -- warmup iteration
	  if (i == -1)
	  {
		  //sdkResetTimer(&hTimer);
		  //sdkStartTimer(&hTimer);
		  if (timeRestrict){
			  double timePerIter = totalTime / c;
			  nIter = int(double(secs * 1000) / timePerIter);
			  printf("Adjust Iters to %d for meeting time requirement %d secs.\n", nIter, secs);
		  }
		  c = 0;
		  totalTime = 0;
	  }

  }

  averMsecs = totalTime / (double)nIter;
  printf("bpnn_layerforward_CUDA() iterated %d, average time is %f msec\n", nIter, averMsecs);
	///* Start to recording kernel execution time*/
	//sdkResetTimer(&hTimer);
	//sdkStartTimer(&hTimer);

	//for (unsigned int i = 0; i < nIter; i++)
	//{
	//	bpnn_layerforward_CUDA << < grid, threads >> >(input_cuda,
	//		output_hidden_cuda,
	//		input_hidden_cuda,
	//		hidden_partial_sum,
	//		in,
	//		hid);
	//}

	//checkCudaErrors(cudaDeviceSynchronize());
	//sdkStopTimer(&hTimer);
	//gpuTime_1 = sdkGetTimerValue(&hTimer) / (float)nIter;
	//printf("Average bpnn_layerforward_CUDA() time: %f msecs;\n", gpuTime_1);


		cudaMemcpy(partial_sum, hidden_partial_sum, num_blocks * WIDTH * sizeof(float), cudaMemcpyDeviceToHost);
     
	  for (int j = 1; j <= hid; j++) {
		sum = 0.0;
		for (int k = 0; k < num_blocks; k++) {	
		  sum += partial_sum[k * hid + j-1] ;
		}
		sum += net->input_weights[0][j];
		net-> hidden_units[j] = float(1.0 / (1.0 + exp(-sum)));
	  }
  #endif

  bpnn_layerforward(net->hidden_units, net->output_units, net->hidden_weights, hid, out);
  bpnn_output_error(net->output_delta, net->target, net->output_units, out, &out_err);
  bpnn_hidden_error(net->hidden_delta, hid, net->output_delta, out, net->hidden_weights, net->hidden_units, &hid_err);  
  bpnn_adjust_weights(net->output_delta, out, net->hidden_units, hid, net->hidden_weights, net->hidden_prev_weights);

#ifdef CPU

  bpnn_adjust_weights(net->hidden_delta, hid, net->input_units, in, net->input_weights, net->input_prev_weights);

#endif  


#ifdef GPU

	  cudaMalloc((void**) &hidden_delta_cuda, (hid + 1) * sizeof(float));
	  cudaMalloc((void**) &input_prev_weights_cuda, (in + 1) * (hid + 1) * sizeof(float));

	  cudaMemcpy(hidden_delta_cuda, net->hidden_delta, (hid + 1) * sizeof(float), cudaMemcpyHostToDevice);
	  cudaMemcpy(input_prev_weights_cuda, input_weights_prev_one_dim, (in + 1) * (hid + 1) * sizeof(float), cudaMemcpyHostToDevice);
	  cudaMemcpy(input_hidden_cuda, input_weights_one_dim, (in + 1) * (hid + 1) * sizeof(float), cudaMemcpyHostToDevice);

	  totalTime = 0;
	  averMsecs = 0;
	  c = 0;

	  for (int i = -20; i < nIter; i++){

		  cudaEvent_t start, stop;
		  // Record the start event
		  checkCudaErrors(cudaEventCreate(&start));
		  checkCudaErrors(cudaEventCreate(&stop));


		  // Run kernel and record the time
		  checkCudaErrors(cudaEventRecord(start, NULL));

			bpnn_adjust_weights_cuda<<< grid, threads >>>(hidden_delta_cuda,  
													hid, 
													input_cuda, 
													in,
													input_hidden_cuda, 
													input_prev_weights_cuda
													);
			cudaDeviceSynchronize();

			cudaError_t error = cudaGetLastError();
			if (error != cudaSuccess) {
				printf("bpnn kernel error: %s\n", cudaGetErrorString(error));
				exit(EXIT_FAILURE);
			}

			checkCudaErrors(cudaEventRecord(stop, NULL));

			// Wait for the stop event to complete
			checkCudaErrors(cudaEventSynchronize(stop));
			float msecCurIter = 0.0f;
			checkCudaErrors(cudaEventElapsedTime(&msecCurIter, start, stop));

			totalTime += msecCurIter;
			c++;
			//iter == -1 -- warmup iteration
			if (i == -1)
			{
				//sdkResetTimer(&hTimer);
				//sdkStartTimer(&hTimer);
				if (timeRestrict){
					double timePerIter = totalTime / c;
					nIter = int(double(secs * 1000) / timePerIter);
					printf("Adjust Iters to %d for meeting time requirement %d secs.\n", nIter, secs);
				}
				c = 0;
				totalTime = 0;
			}

	  }

	  averMsecs = totalTime / (double)nIter;
	  printf("bpnn_adjust_weights_cuda() iterated %d, average time is %f msec\n", nIter, averMsecs);
 

  ///* Start to recording kernel execution time*/
  //sdkResetTimer(&hTimer);
  //sdkStartTimer(&hTimer);

  //for (unsigned int i = 0; i < nIter; i++)
  //{
	 // bpnn_adjust_weights_cuda << < grid, threads >> >(hidden_delta_cuda,
		//  hid,
		//  input_cuda,
		//  in,
		//  input_hidden_cuda,
		//  input_prev_weights_cuda
		//  );
  //}

  //checkCudaErrors(cudaDeviceSynchronize());
  //sdkStopTimer(&hTimer);
  //gpuTime_2 = sdkGetTimerValue(&hTimer) / (float)nIter;
  //printf("Average bpnn_adjust_weights_cuda() time: %f msecs;\n", gpuTime_2);

  //printf("Total Time of the two kernels: %f msecs;\n", gpuTime_1 + gpuTime_2);

  cudaMemcpy(net->input_units, input_cuda, (in + 1) * sizeof(float), cudaMemcpyDeviceToHost);
  cudaMemcpy(input_weights_one_dim, input_hidden_cuda, (in + 1) * (hid + 1) * sizeof(float), cudaMemcpyDeviceToHost);
  cudaThreadSynchronize();

   //sdkStopTimer(&hTimer);
   //gpuTime = sdkGetTimerValue(&hTimer);
   
  cudaFree(input_cuda);
  cudaFree(output_hidden_cuda);
  cudaFree(input_hidden_cuda);
  cudaFree(hidden_partial_sum);
  cudaFree(input_prev_weights_cuda);
  cudaFree(hidden_delta_cuda);
  
  free(partial_sum);
  free(input_weights_one_dim);
  free(input_weights_prev_one_dim);

#endif   
  
  
  

}
