/*
 * Copyright 1993-2014 NVIDIA Corporation.  All rights reserved.
 *
 * Please refer to the NVIDIA end user license agreement (EULA) associated
 * with this source code for terms and conditions that govern your use of
 * this software. Any use, reproduction, disclosure, or distribution of
 * this software and related documentation outside the terms of the EULA
 * is strictly prohibited.
 *
 */


/*
    Parallel reduction

    This sample shows how to perform a reduction operation on an array of values
    to produce a single value.

    Reductions are a very common computation in parallel algorithms.  Any time
    an array of values needs to be reduced to a single value using a binary
    associative operator, a reduction can be used.  Example applications include
    statistics computaions such as mean and standard deviation, and image
    processing applications such as finding the total luminance of an
    image.

    This code performs sum reductions, but any associative operator such as
    min() or max() could also be used.

    It assumes the input size is a power of 2.

    COMMAND LINE ARGUMENTS

    "--shmoo":         Test performance for 1 to 32M elements with each of the 7 different kernels
    "--n=<N>":         Specify the number of elements to reduce (default 1048576)
    "--threads=<N>":   Specify the number of threads per block (default 128)
    "--kernel=<N>":    Specify which kernel to run (0-6, default 6)
    "--maxblocks=<N>": Specify the maximum number of thread blocks to launch (kernel 6 only, default 64)
    "--cpufinal":      Read back the per-block results and do final sum of block sums on CPU (default false)
    "--cputhresh=<N>": The threshold of number of blocks sums below which to perform a CPU final reduction (default 1)
    "-type=<T>":       The datatype for the reduction, where T is "int", "float", or "double" (default int)
*/

// CUDA Runtime
#include <cuda_runtime.h>

// Utilities and system includes
#include <helper_cuda.h>
#include <helper_functions.h>
#include <algorithm>

// includes, project
#include "reduction.h"
#include "reduction_kernel.cu"

enum ReduceType
{
    REDUCE_INT,
    REDUCE_FLOAT,
    REDUCE_DOUBLE
};

////////////////////////////////////////////////////////////////////////////////
// declaration, forward
template <class T>
bool runTest(int argc, char **argv, ReduceType datatype);


#define MAX_BLOCK_DIM_SIZE 65535

#ifdef WIN32
#define strcasecmp strcmpi
#endif

extern "C"
bool isPow2(unsigned int x)
{
    return ((x&(x-1))==0);
}


int nIter = 500;
int secs = 60;
int timeRestrict = 0;
////////////////////////////////////////////////////////////////////////////////
// Program main
////////////////////////////////////////////////////////////////////////////////
int
main(int argc, char **argv)
{
    printf("%s Starting...\n\n", argv[0]);

    char *typeChoice = 0;
    getCmdLineArgumentString(argc, (const char **) argv, "type", &typeChoice);

    ReduceType datatype = REDUCE_INT;

    if (0 != typeChoice)
    {
        if (!strcasecmp(typeChoice, "float"))
        {
            datatype = REDUCE_FLOAT;
        }
        else if (!strcasecmp(typeChoice, "double"))
        {
            datatype = REDUCE_DOUBLE;
        }
        else
        {
            datatype = REDUCE_INT;
        }
    }

    cudaDeviceProp deviceProp;
    deviceProp.major = 1;
    deviceProp.minor = 0;
    int minimumComputeVersion = 10;

    if (datatype == REDUCE_DOUBLE)
    {
        deviceProp.minor = 3;
        minimumComputeVersion = 13;
    }

    int dev;

    dev = findCudaDevice(argc, (const char **)argv);


    checkCudaErrors(cudaGetDeviceProperties(&deviceProp, dev));

    if ((deviceProp.major * 10 + deviceProp.minor) >= minimumComputeVersion)
    {
        printf("Using Device %d: %s\n\n", dev, deviceProp.name);
        checkCudaErrors(cudaSetDevice(dev));
    }
    else
    {
        printf("Error: the selected device does not support the minimum compute capability of %d.%d.\n\n",
               minimumComputeVersion / 10, minimumComputeVersion % 10);

        // cudaDeviceReset causes the driver to clean up all state. While
        // not mandatory in normal operation, it is good practice.  It is also
        // needed to ensure correct operation when the application is being
        // profiled. Calling cudaDeviceReset causes all profile data to be
        // flushed before the application exits
        cudaDeviceReset();
        exit(EXIT_FAILURE);
    }

    printf("Reducing array of type %s\n\n", typeChoice);

    bool bResult = false;

    switch (datatype)
    {
        default:
        case REDUCE_INT:
            bResult = runTest<int>(argc, argv, datatype);
            break;

        case REDUCE_FLOAT:
            bResult = runTest<float>(argc, argv, datatype);
            break;

        case REDUCE_DOUBLE:
            bResult = runTest<double>(argc, argv, datatype);
            break;
    }

    // cudaDeviceReset causes the driver to clean up all state. While
    // not mandatory in normal operation, it is good practice.  It is also
    // needed to ensure correct operation when the application is being
    // profiled. Calling cudaDeviceReset causes all profile data to be
    // flushed before the application exits
    cudaDeviceReset();
    printf(bResult ? "Test passed\n" : "Test failed!\n");
}

////////////////////////////////////////////////////////////////////////////////
//! Compute sum reduction on CPU
//! We use Kahan summation for an accurate sum of large arrays.
//! http://en.wikipedia.org/wiki/Kahan_summation_algorithm
//!
//! @param data       pointer to input data
//! @param size       number of input data elements
////////////////////////////////////////////////////////////////////////////////
template<class T>
T reduceCPU(T *data, int size)
{
    T sum = data[0];
    T c = (T)0.0;

    for (int i = 1; i < size; i++)
    {
        T y = data[i] - c;
        T t = sum + y;
        c = (t - sum) - y;
        sum = t;
    }

    return sum;
}

unsigned int nextPow2(unsigned int x)
{
    --x;
    x |= x >> 1;
    x |= x >> 2;
    x |= x >> 4;
    x |= x >> 8;
    x |= x >> 16;
    return ++x;
}

#ifndef MIN
#define MIN(x,y) ((x < y) ? x : y)
#endif

////////////////////////////////////////////////////////////////////////////////
// Compute the number of threads and blocks to use for the given reduction kernel
// For the kernels >= 3, we set threads / block to the minimum of maxThreads and
// n/2. For kernels < 3, we set to the minimum of maxThreads and n.  For kernel
// 6, we observe the maximum specified number of blocks, because each thread in
// that kernel can process a variable number of elements.
////////////////////////////////////////////////////////////////////////////////
void getNumBlocksAndThreads(int whichKernel, int n, int maxBlocks, int maxThreads, int &blocks, int &threads)
{

    //get device capability, to avoid block/grid size excceed the upbound
    cudaDeviceProp prop;
    int device;
    checkCudaErrors(cudaGetDevice(&device));
    checkCudaErrors(cudaGetDeviceProperties(&prop, device));

    if (whichKernel < 3)
    {
        threads = (n < maxThreads) ? nextPow2(n) : maxThreads;
        blocks = (n + threads - 1) / threads;
    }
    else
    {
        threads = (n < maxThreads*2) ? nextPow2((n + 1)/ 2) : maxThreads;
        blocks = (n + (threads * 2 - 1)) / (threads * 2);
    }

    if ((float)threads*blocks > (float)prop.maxGridSize[0] * prop.maxThreadsPerBlock)
    {
        printf("n is too large, please choose a smaller number!\n");
    }

    if (blocks > prop.maxGridSize[0])
    {
        printf("Grid size <%d> excceeds the device capability <%d>, set block size as %d (original %d)\n",
               blocks, prop.maxGridSize[0], threads*2, threads);

        blocks /= 2;
        threads *= 2;
    }

    if (whichKernel == 6)
    {
        blocks = MIN(maxBlocks, blocks);
    }
}

////////////////////////////////////////////////////////////////////////////////
// This function performs a reduction of the input data multiple times and
// measures the average reduction time.
////////////////////////////////////////////////////////////////////////////////
template <class T>
T benchmarkReduce(int  n,
                  int  numThreads,
                  int  numBlocks,
                  int  maxThreads,
                  int  maxBlocks,
                  int  whichKernel,
                  int  testIterations,
                  bool cpuFinalReduction,
                  int  cpuFinalThreshold,
                  StopWatchInterface *timer,
                  T *h_odata,
                  T *d_idata,
                  T *d_odata)
{
    T gpu_result = 0;
    bool needReadBack = true;

    for (int i = 0; i < testIterations; ++i)
    {
        gpu_result = 0;

        cudaDeviceSynchronize();
        sdkStartTimer(&timer);

        // execute the kernel
        reduce<T>(n, numThreads, numBlocks, whichKernel, d_idata, d_odata);

        // check if kernel execution generated an error
        getLastCudaError("Kernel execution failed");

        //if (cpuFinalReduction)
        //{
        //    // sum partial sums from each block on CPU
        //    // copy result from device to host
        //    checkCudaErrors(cudaMemcpy(h_odata, d_odata, numBlocks*sizeof(T), cudaMemcpyDeviceToHost));

        //    for (int i=0; i<numBlocks; i++)
        //    {
        //        gpu_result += h_odata[i];
        //    }

        //    needReadBack = false;
        //}
        //else
        //{
        //    // sum partial block sums on GPU
        //    int s=numBlocks;
        //    int kernel = whichKernel;

        //    while (s > cpuFinalThreshold)
        //    {
        //        int threads = 0, blocks = 0;
        //        getNumBlocksAndThreads(kernel, s, maxBlocks, maxThreads, blocks, threads);

        //        reduce<T>(s, threads, blocks, kernel, d_odata, d_odata);

        //        if (kernel < 3)
        //        {
        //            s = (s + threads - 1) / threads;
        //        }
        //        else
        //        {
        //            s = (s + (threads*2-1)) / (threads*2);
        //        }
        //    }

        //    if (s > 1)
        //    {
        //        // copy result from device to host
        //        checkCudaErrors(cudaMemcpy(h_odata, d_odata, s * sizeof(T), cudaMemcpyDeviceToHost));

        //        for (int i=0; i < s; i++)
        //        {
        //            gpu_result += h_odata[i];
        //        }

        //        needReadBack = false;
        //    }
        //}

        cudaDeviceSynchronize();
        sdkStopTimer(&timer);
    }

    if (needReadBack)
    {
        // copy final sum from device to host
        checkCudaErrors(cudaMemcpy(&gpu_result, d_odata, sizeof(T), cudaMemcpyDeviceToHost));
    }

    return gpu_result;
}

////////////////////////////////////////////////////////////////////////////////
// This function calls benchmarkReduce multiple times for a range of array sizes
// and prints a report in CSV (comma-separated value) format that can be used for
// generating a "shmoo" plot showing the performance for each kernel variation
// over a wide range of input sizes.
////////////////////////////////////////////////////////////////////////////////
template <class T>
void shmoo(int minN, int maxN, int maxThreads, int maxBlocks, ReduceType datatype)
{
    // create random input data on CPU
    unsigned int bytes = maxN * sizeof(T);

    T *h_idata = (T *) malloc(bytes);

    for (int i = 0; i < maxN; i++)
    {
        // Keep the numbers small so we don't get truncation error in the sum
        if (datatype == REDUCE_INT)
        {
            h_idata[i] = (T)(rand() & 0xFF);
        }
        else
        {
            h_idata[i] = (rand() & 0xFF) / (T)RAND_MAX;
        }
    }

    int maxNumBlocks = MIN(maxN / maxThreads, MAX_BLOCK_DIM_SIZE);

    // allocate mem for the result on host side
    T *h_odata = (T *) malloc(maxNumBlocks*sizeof(T));

    // allocate device memory and data
    T *d_idata = NULL;
    T *d_odata = NULL;

    checkCudaErrors(cudaMalloc((void **) &d_idata, bytes));
    checkCudaErrors(cudaMalloc((void **) &d_odata, maxNumBlocks*sizeof(T)));

    // copy data directly to device memory
    checkCudaErrors(cudaMemcpy(d_idata, h_idata, bytes, cudaMemcpyHostToDevice));
    checkCudaErrors(cudaMemcpy(d_odata, h_idata, maxNumBlocks*sizeof(T), cudaMemcpyHostToDevice));

    // warm-up
    for (int kernel = 0; kernel < 7; kernel++)
    {
        reduce<T>(maxN, maxThreads, maxNumBlocks, kernel, d_idata, d_odata);
    }

    StopWatchInterface *timer = 0;
    sdkCreateTimer(&timer);

    // print headers
    printf("Time in milliseconds for various numbers of elements for each kernel\n\n\n");
    printf("Kernel");

    for (int i = minN; i <= maxN; i *= 2)
    {
        printf(", %d", i);
    }

    for (int kernel = 0; kernel < 7; kernel++)
    {
        printf("\n%d", kernel);

        for (int i = minN; i <= maxN; i *= 2)
        {
            sdkResetTimer(&timer);
            int numBlocks = 0;
            int numThreads = 0;
            getNumBlocksAndThreads(kernel, i, maxBlocks, maxThreads, numBlocks, numThreads);

            float reduceTime;

            if (numBlocks <= MAX_BLOCK_DIM_SIZE)
            {
                benchmarkReduce(i, numThreads, numBlocks, maxThreads, maxBlocks, kernel,
                                nIter, false, 1, timer, h_odata, d_idata, d_odata);
                reduceTime =  sdkGetAverageTimerValue(&timer);
            }
            else
            {
                reduceTime = -1.0;
            }

            printf(", %.5f", reduceTime);
        }
    }

    // cleanup
    sdkDeleteTimer(&timer);
    free(h_idata);
    free(h_odata);

    checkCudaErrors(cudaFree(d_idata));
    checkCudaErrors(cudaFree(d_odata));
}

////////////////////////////////////////////////////////////////////////////////
// The main function whihc runs the reduction test.
////////////////////////////////////////////////////////////////////////////////
template <class T>
bool
runTest(int argc, char **argv, ReduceType datatype)
{
    int size = 1<<24;    // number of elements to reduce
    int maxThreads = 256;  // number of threads per block
    int whichKernel = 6;
    int maxBlocks = 64;
    //bool cpuFinalReduction = false;
    //int cpuFinalThreshold = 1;

    if (checkCmdLineFlag(argc, (const char **) argv, "n"))
    {
        size = getCmdLineArgumentInt(argc, (const char **) argv, "n") * 1048576;
    }

    if (checkCmdLineFlag(argc, (const char **) argv, "threads"))
    {
        maxThreads = getCmdLineArgumentInt(argc, (const char **) argv, "threads");
    }

    if (checkCmdLineFlag(argc, (const char **) argv, "kernel"))
    {
        whichKernel = getCmdLineArgumentInt(argc, (const char **) argv, "kernel");
    }

    if (checkCmdLineFlag(argc, (const char **) argv, "maxblocks"))
    {
        maxBlocks = getCmdLineArgumentInt(argc, (const char **) argv, "maxblocks");
    }

	// Iteration count
	if (checkCmdLineFlag(argc, (const char **)argv, "iters"))
	{
		nIter = getCmdLineArgumentInt(argc, (const char **)argv, "iters");
	}

	// Iteration count
	if (checkCmdLineFlag(argc, (const char **)argv, "secs"))
	{
		secs = getCmdLineArgumentInt(argc, (const char **)argv, "secs");
		timeRestrict = 1;
	}

    printf("%d elements\n", size);
    printf("%d threads (max)\n", maxThreads);

    //cpuFinalReduction = checkCmdLineFlag(argc, (const char **) argv, "cpufinal");

    //if (checkCmdLineFlag(argc, (const char **) argv, "cputhresh"))
    //{
    //    cpuFinalThreshold = getCmdLineArgumentInt(argc, (const char **) argv, "cputhresh");
    //}

    bool runShmoo = checkCmdLineFlag(argc, (const char **) argv, "shmoo");

    if (runShmoo)
    {
        shmoo<T>(1, 33554432, maxThreads, maxBlocks, datatype);
    }
    else
    {
        // create random input data on CPU
        unsigned int bytes = size * sizeof(T);

        T *h_idata = (T *) malloc(bytes);

        for (int i=0; i<size; i++)
        {
            // Keep the numbers small so we don't get truncation error in the sum
            if (datatype == REDUCE_INT)
            {
                h_idata[i] = (T)(rand() & 0xFF);
            }
            else
            {
                h_idata[i] = (rand() & 0xFF) / (T)RAND_MAX;
				//printf("%d: %f.\n", i, h_idata[i]);
            }
        }

        int numBlocks = 0;
        int numThreads = 0;
        getNumBlocksAndThreads(whichKernel, size, maxBlocks, maxThreads, numBlocks, numThreads);

        //if (numBlocks == 1)
        //{
        //    cpuFinalThreshold = 1;
        //}

        // allocate mem for the result on host side
        T *h_odata = (T *) malloc(numBlocks*sizeof(T));

        printf("%d blocks\n\n", numBlocks);

        // allocate device memory and data
        T *d_idata = NULL;
        T *d_odata = NULL;

        checkCudaErrors(cudaMalloc((void **) &d_idata, bytes));
        checkCudaErrors(cudaMalloc((void **) &d_odata, numBlocks*sizeof(T)));

        // copy data directly to device memory
        checkCudaErrors(cudaMemcpy(d_idata, h_idata, bytes, cudaMemcpyHostToDevice));
        checkCudaErrors(cudaMemcpy(d_odata, h_idata, numBlocks*sizeof(T), cudaMemcpyHostToDevice));

		dim3 dimBlock(numThreads, 1, 1);
		dim3 dimGrid(numBlocks, 1, 1);

		// when there is only one warp per block, we need to allocate two warps
		// worth of shared memory so that we don't index shared memory out of bounds
		int smemSize = (numThreads <= 32) ? 2 * numThreads * sizeof(T) : numThreads * sizeof(T);

		// warming up
		reduce2(dimGrid, dimBlock, smemSize, d_idata, d_odata, size);
		checkCudaErrors(cudaDeviceSynchronize());

		cudaEvent_t start, stop;
		// Record the start event
		checkCudaErrors(cudaEventCreate(&start));
		checkCudaErrors(cudaEventCreate(&stop));
		double totalTime = 0.0;

		int k = -1;
		while (k < nIter)
		{
			// Run kernel and record the time
			checkCudaErrors(cudaEventRecord(start, NULL));

			reduce2<T>(dimGrid, dimBlock, smemSize, d_idata, d_odata, size);

			cudaThreadSynchronize();

			checkCudaErrors(cudaEventRecord(stop, NULL));

			// Wait for the stop event to complete
			checkCudaErrors(cudaEventSynchronize(stop));
			float msecTotal = 0.0f;
			checkCudaErrors(cudaEventElapsedTime(&msecTotal, start, stop));

			//iter == -1 -- warmup iteration
			if (k == -1)
			{
				checkCudaErrors(cudaDeviceSynchronize());
				//sdkResetTimer(&hTimer);
				//sdkStartTimer(&hTimer);
				if (timeRestrict){
					nIter = secs / (msecTotal * 0.001);
					printf("Adjust Iters to %d for meeting time requirement %d secs.\n", nIter, secs);
				}
			}
			else
			{
				totalTime += msecTotal;
			}

			k++;

		}

		checkCudaErrors(cudaDeviceSynchronize());
		printf("iterated %d, average time is %f msecs.\n", nIter, totalTime / (float)nIter);

		// copy final sum from device to host
		T gpu_result = 0;
		// sum partial sums from each block on CPU
		// copy result from device to host
		checkCudaErrors(cudaMemcpy(h_odata, d_odata, numBlocks*sizeof(T), cudaMemcpyDeviceToHost));

		for (int i=0; i<numBlocks; i++)
		{
		    gpu_result += h_odata[i];
		}

        // compute reference solution
        T cpu_result = reduceCPU<T>(h_idata, size);

        double threshold = 1e-12;
        double diff = 0;

        if (datatype == REDUCE_INT)
        {
            printf("\nGPU result = %d\n", (int)gpu_result);
            printf("CPU result = %d\n\n", (int)cpu_result);
        }
        else
        {
            printf("\nGPU result = %f\n", (double)gpu_result);
            printf("CPU result = %f\n\n", (double)cpu_result);

            if (datatype == REDUCE_FLOAT)
            {
                threshold = 1e-8 * size;
            }

            diff = fabs((double)gpu_result - (double)cpu_result);
        }

        // cleanup
        free(h_idata);
        free(h_odata);

        checkCudaErrors(cudaFree(d_idata));
        checkCudaErrors(cudaFree(d_odata));

        if (datatype == REDUCE_INT)
        {
            return (gpu_result == cpu_result);
        }
        else
        {
            return (diff < threshold);
        }
    }

    return true;
}

