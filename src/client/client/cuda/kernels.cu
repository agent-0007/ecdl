#include <cuda.h>
#include <cuda_runtime.h>
#include <device_launch_parameters.h>
#include <stdlib.h>
#include "Fp.cu"
#include <stdio.h>

#define NUM_R_POINTS 32 // Must be a power of 2
#define R_POINT_MASK (NUM_R_POINTS - 1)



/**
 * Bit mask for identifying distinguished points
 */
__constant__ unsigned int _MASK[ 2 ];

/**
 * The X coordinates of the R points
 */
__constant__ unsigned int _rx[ 10 * NUM_R_POINTS ];

/**
 * The Y coordinates of the Y points
 */
__constant__ unsigned int _ry[ 10 * NUM_R_POINTS ];

/**
 * Shared memory to hold the R points
 */
__shared__ unsigned int _shared_rx[ 10 * NUM_R_POINTS ];
__shared__ unsigned int _shared_ry[ 10 * NUM_R_POINTS ];


/**
 * Point at infinity
 */
__device__ unsigned int _pointAtInfinity[10] = { 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff,
                                                 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff};

/**
 * Reads Rx[i] from shared memory
 */
template<int N> __device__ void getRX(int index, unsigned int *rx)
{
    for(int i = 0; i < N; i++) {
        rx[i] = _shared_rx[32 * i + index];
    }
}

/**
 * Reads Ry[i] from shared memory
 */
template<int N> __device__ void getRY(int index, unsigned int *ry)
{
    for(int i = 0; i < N; i++) {
        ry[ i ] = _shared_ry[32 * i + index];
    }
}


/**
 * Reads Rx and Ry from constant memory and writes them to shared memory
 */
__device__ void initSharedMem(unsigned int len)
{
    if(threadIdx.x == 0) {
        for(int i = 0; i < len; i++) {
            for(int j = 0; j < 32; j++) {
                _shared_rx[i * 32 + j] = _rx[ len * j + i];
                _shared_ry[i * 32 + j] = _ry[ len * j + i];
            }
        }
    }
    __syncthreads();
}

template<int N> __device__ void doMultiplyStep(const unsigned int *aMultiplier, const unsigned int *bMultiplier,
                                  const unsigned int *gx, const unsigned int *gy,
                                  const unsigned int *qx, const unsigned int *qy,
                                  const unsigned int *gqx, const unsigned int *gqy,
                                  unsigned int *xAra, unsigned int *yAra,
                                  unsigned int *diffBuf, unsigned int *chainBuf,
                                  int step, unsigned int pointsPerThread)
{
    unsigned int product[N] = {0};

    product[0] = 1;

    unsigned int mask = 1 << (step % 32);
    int word = step / 32;
  
    // To compute (Px - Qx)^-1, multiply together all the differences and then perfom
    // a single inversion. After each multiplication, store the product.
    for(int i = 0; i < pointsPerThread; i++) {
        unsigned int bpx[N];
        unsigned int x[N];

        readBigInt<N>(xAra, i, x);
        unsigned int diff[N];

        // For point at infinity we set the difference as 2 so the math still
        // works out 
        unsigned int am = readBigIntWord<N>(aMultiplier, i, word);
        unsigned int bm = readBigIntWord<N>(bMultiplier, i, word);

        if( (am | bm) & mask == 0 || equalTo<N>(x, _pointAtInfinity) ) {
            zero<N>(diff);
            diff[0] = 2;
        } else {
            if( (am & ~bm) & mask ) {
                copy<N>(&gx[step * N], bpx);
            } else if( (~am & bm) & mask) {
                copy<N>(&qx[step * N], bpx);
            } else {
                copy<N>(&gqx[step * N], bpx);
            }
            subModP<N>(x, bpx, diff);
        }

        writeBigInt<N>(diffBuf, i, diff);

        multiplyModP<N>(product, diff, product);
        writeBigInt<N>(chainBuf, i, product);
    }

    // Compute the inverse
    unsigned int inverse[N];
    inverseModP<N>(product, inverse);

    // Multiply by the products stored perviously so that they are canceled out
    for(int i = pointsPerThread - 1; i >= 0; i--) {
        // Get the inverse of the last difference by multiplying the inverse of the product of all the differences
        // with the product of all but the last difference
        unsigned int invDiff[N];
        if( i >= 1) {
            unsigned int tmp[N];
            readBigInt<N>(chainBuf, i - 1, tmp);
            multiplyModP<N>(inverse, tmp, invDiff);

            // Cancel out the last difference
            readBigInt<N>(diffBuf, i, tmp);
            multiplyModP<N>(inverse, tmp, inverse);
        } else {
            copy<N>(inverse, invDiff);
        }
      
        unsigned int am = readBigIntWord<N>( aMultiplier, i, word );
        unsigned int bm = readBigIntWord<N>( bMultiplier, i, word );

        if((am & mask) != 0 || (bm & mask) != 0 ) {
            unsigned int px[N];
            unsigned int py[N];
            unsigned int bpx[N];
            unsigned int bpy[N];
          
            // Select G, Q, or G+Q 
            if((am & ~bm) & mask ) {
                copy<N>(&gx[step *N], bpx);
                copy<N>(&gy[step *N], bpy);
            } else if((~am & bm) & mask) {
                copy<N>(&qx[step *N], bpx);
                copy<N>(&qy[step *N], bpy);
            } else {
                copy<N>(&gqx[step *N], bpx);
                copy<N>(&gqy[step *N], bpy);
            }

            // Load the current point
            readBigInt<N>(xAra, i, px);
            readBigInt<N>(yAra, i, py);

            if(equalTo<N>( px, _pointAtInfinity)) {
                writeBigInt<N>(xAra, i, bpx);
                writeBigInt<N>(yAra, i, bpy);
            } else {
                unsigned int s[N];
                unsigned int rx[N];
                unsigned int s2[N];

                // s = Py - Qy / Px - Qx
                subModP<N>(py, bpy, s);
                multiplyModP<N>(invDiff, s, s);
                squareModP<N>(s, s2);

                // Rx = s^2 - Px - Qx
                subModP<N>(s2, px, rx);
                subModP<N>(rx, bpx, rx);

                // Ry = -Py + s(Px - Rx)
                unsigned int k[N];
                subModP<N>(px, rx, k);
                multiplyModP<N>(k, s, k);
                unsigned int ry[N];

                subModP<N>(k, py, ry);

                writeBigInt<N>(xAra, i, rx);
                writeBigInt<N>(yAra, i, ry);
            }
        }
    }
}

/**
 * Based on the bit values of a and b, G, Q, or (G+Q) will be added
 */
__global__ void startingPointGenKernel(const unsigned int *a, const unsigned int *b,
                                       const unsigned int *gx, const unsigned int *gy,
                                       const unsigned int *qx, const unsigned int *qy,
                                       const unsigned int *gqx, const unsigned int *gqy,
                                       unsigned int *rx, unsigned int *ry,
                                       unsigned int *diffBuf, unsigned int *chainBuf,
                                       int step, unsigned int pointsPerThread)
{
    initFp();
    initSharedMem(_PWORDS);

    switch(_PWORDS) {
        case 2:
        doMultiplyStep<2>( a, b, gx, gy, qx, qy, gqx, gqy, rx, ry, diffBuf, chainBuf, step, pointsPerThread);
        break; 
        case 3:
        doMultiplyStep<3>( a, b, gx, gy, qx, qy, gqx, gqy, rx, ry, diffBuf, chainBuf, step, pointsPerThread);
        break;
        case 4:
        doMultiplyStep<4>( a, b, gx, gy, qx, qy, gqx, gqy, rx, ry, diffBuf, chainBuf, step, pointsPerThread);
        break;
        case 5:
        doMultiplyStep<5>( a, b, gx, gy, qx, qy, gqx, gqy, rx, ry, diffBuf, chainBuf, step, pointsPerThread);
        break;
        case 6:
        doMultiplyStep<6>( a, b, gx, gy, qx, qy, gqx, gqy, rx, ry, diffBuf, chainBuf, step, pointsPerThread);
        break;
        case 7:
        doMultiplyStep<7>( a, b, gx, gy, qx, qy, gqx, gqy, rx, ry, diffBuf, chainBuf, step, pointsPerThread);
        break;
        case 8:
        doMultiplyStep<8>( a, b, gx, gy, qx, qy, gqx, gqy, rx, ry, diffBuf, chainBuf, step, pointsPerThread);
        break;
    }
}

/**
 * Resets all points on the device to the point at infinity
 */
__device__ void resetPointsFunc(unsigned int *rx, unsigned int *ry, int pointsPerThread)
{
    for(int i = 0; i < pointsPerThread; i++)
    {
        writeBigInt(rx, i, _pointAtInfinity, _PWORDS);
        writeBigInt(ry, i, _pointAtInfinity, _PWORDS);
    }
}

/**
 * Kernel to reset all points on the device to the point at infinity
 */
__global__ void resetPointsKernel( unsigned int *rx, unsigned int *ry, int pointsPerThread)
{
    resetPointsFunc(rx, ry, pointsPerThread);
}


/**
 * Sets the number of distinguished bits to look for
 */
static cudaError_t setNumDistinguishedBits(unsigned int dBits)
{
    unsigned int mask[2] = {0xffffffff, 0xffffffff};
    if(dBits > 32) {
        mask[ 1 ] >>= (32 - (dBits - 32));
    } else {
        mask[ 0 ] >>= (32 - dBits);
        mask[ 1 ] = 0;
    }
    return cudaMemcpyToSymbol(_MASK, mask, sizeof(mask), 0, cudaMemcpyHostToDevice);
}


/**
 * Subtract 2 from a big integer
 */
static void sub2(const unsigned int *a, unsigned int *c, int len)
{
    unsigned int borrowOut = 0;
    unsigned int borrowIn = 2;

    for( int i = 0; i < len; i++ ) {
      
        unsigned int d = a[ i ] - borrowIn;

        if(d > a[i]) {
            borrowOut = 1;
        } else {
            borrowOut = 0;
        }

        borrowIn = borrowOut;
        c[i] = d;
    }
}

/**
 * Shift a big integer left by n bits
 */
static void shiftLeft(const unsigned int *a, int n, unsigned int *c, int len)
{
    unsigned int out = 0;
    unsigned int in = 0;
    for(int i = 0; i < len; i++) {
        out = a[i] >> (32 - n);
        c[i] = a[i] << n;
        c[i] |= in;
        in = out;
    }
}

/**
 * Add two big integers
 */
static void addInt(const unsigned int *a, const unsigned int *b, unsigned int *c, int len)
{
    unsigned int carryIn = 0;
    unsigned int carryOut = 0;
    for(int i = 0; i < len; i++) {

        unsigned int s = a[i] + b[i];

        if(s < a[i]) {
            carryOut = 1;
        } else {
            carryOut = 0;
        }

        s += carryIn;

        carryIn = carryOut;

        c[i] = s;
    }
}

/**
 * Set parameters for the prime field library
 */
static cudaError_t setFpParameters(const unsigned int *pPtr, unsigned int pBits, const unsigned int *mPtr, unsigned int mBits)
{
    cudaError_t cudaError = cudaSuccess;
    unsigned int pWords = (pBits + 31) / 32;
    unsigned int mWords = (mBits + 31) / 32;
    unsigned int p2Words = (pBits + 1 + 31) / 32;
    unsigned int p3Words = (pBits + 2 + 31) / 32;

    unsigned int p[10] = {0};
    unsigned int pTimes2[10] = {0};
    unsigned int pTimes3[10] = {0};
    unsigned int pMinus2[10] = {0};

    // copy p into buffer
    for(unsigned int i = 0; i < pWords; i++) {
        p[i] = pPtr[i];
    }

    // compute p - 2
    sub2(p, pMinus2, 10);

    // compute 2 * p
    shiftLeft(p, 1, pTimes2, 10);

    // compute 3 * p
    addInt(p, pTimes2, pTimes3, 10);

    cudaError = cudaMemcpyToSymbol(_P_CONST, p, sizeof(unsigned int)*pWords, 0, cudaMemcpyHostToDevice);
    if(cudaError != cudaSuccess) {
        goto end;
    }
    
    cudaError = cudaMemcpyToSymbol(_PMINUS2_CONST, pMinus2, sizeof(unsigned int)*pWords, 0, cudaMemcpyHostToDevice);
    if(cudaError != cudaSuccess) {
        goto end;
    }
    
    cudaError = cudaMemcpyToSymbol(_M_CONST, mPtr, sizeof(unsigned int)*mWords, 0, cudaMemcpyHostToDevice);
    if(cudaError != cudaSuccess) {
        goto end;
    }

    cudaError = cudaMemcpyToSymbol(_PBITS_CONST, &pBits, sizeof(pBits), 0, cudaMemcpyHostToDevice);
    if(cudaError != cudaSuccess) {
        goto end;
    }

    cudaError = cudaMemcpyToSymbol(_2P_CONST, pTimes2, sizeof(unsigned int) * p2Words, 0, cudaMemcpyHostToDevice);
    if(cudaError != cudaSuccess) {
        goto end;
    }

    cudaError = cudaMemcpyToSymbol(_3P_CONST, pTimes3, sizeof(unsigned int) * p3Words, 0, cudaMemcpyHostToDevice);
    if(cudaError != cudaSuccess) {
        goto end;
    }

    cudaError = cudaMemcpyToSymbol(_PWORDS, &pWords, sizeof(unsigned int), 0, cudaMemcpyHostToDevice);
    if(cudaError != cudaSuccess) {
        goto end;
    }

    cudaError = cudaMemcpyToSymbol(_MWORDS, &mWords, sizeof(unsigned int), 0, cudaMemcpyHostToDevice);
    if(cudaError != cudaSuccess) {
        goto end;
    }


    cudaError = cudaMemcpyToSymbol(_MBITS_CONST, &mBits, sizeof(mBits), 0, cudaMemcpyHostToDevice);
    
end:
    return cudaError;
}


/**
 * Initialize device parameters
 */
cudaError_t initDeviceParams(const unsigned int *p, unsigned int pBits, const unsigned int *m, unsigned int mBits, unsigned int dBits)
{
    cudaError_t cudaError = setFpParameters(p, pBits, m, mBits);
    if(cudaError != cudaSuccess) {
        goto end;
    }

    cudaError = setNumDistinguishedBits(dBits);

end:
    return cudaError;
}

/**
 * Copy a, b, Rx and Ry to constant memory
 */
cudaError_t copyRPointsToDevice(const unsigned int *rx, const unsigned int *ry, int length, int count)
{
    cudaError_t cudaError = cudaSuccess;
    size_t size = sizeof(unsigned int) * length * count;

    cudaError = cudaMemcpyToSymbol(_rx, rx, size, 0, cudaMemcpyHostToDevice );
    if( cudaError != cudaSuccess ) {
        goto end;
    }

    cudaError = cudaMemcpyToSymbol(_ry, ry, size, 0, cudaMemcpyHostToDevice );
    if( cudaError != cudaSuccess ) {
        goto end;
    }

end:
    return cudaError;
}

cudaError_t multiplyAddG(unsigned int blocks, unsigned int threads, unsigned int pointsPerThread,
                          const unsigned int *a, const unsigned int *b,
                          const unsigned int *gx, const unsigned int *gy,
                          const unsigned int *qx, const unsigned int *qy,
                          const unsigned int *gqx, const unsigned int *gqy,
                          unsigned int *x, unsigned int *y,
                          unsigned int *diffBuf, unsigned int *chainBuf,
                          unsigned int step)
{
    startingPointGenKernel<<<blocks, threads>>>(a, b, gx, gy, qx, qy, gqx, gqy, x, y, diffBuf, chainBuf, step, pointsPerThread);
    return cudaDeviceSynchronize();
}

/**
 * Reset all points to point at infinity
 */
cudaError_t resetPoints(unsigned int blocks, unsigned int threads, unsigned int pointsPerThread, unsigned int *rx, unsigned int *ry)
{
    resetPointsKernel<<<blocks, threads>>>(rx, ry, pointsPerThread);
    return cudaDeviceSynchronize();
}

void __device__ cuPrintBigInt(const unsigned int *x, int len)
{
    for(int i = 0; i < len; i++) {
        printf("%x ", x[i]);
    }
    printf("\n");
}

template<int N> __device__ void doStep(
                            unsigned int *xAra,
                            unsigned int *yAra,
                            unsigned int *diffBuf,
                            unsigned int *chainBuf,
                            unsigned int *blockFlags,
                            unsigned int *pointFlags,
                            unsigned int pointsInParallel) {

    // Initalize to 1
    unsigned int product[N] = {0};
    product[0] = 1;

    // Multiply differences together
    for(int i = 0; i < pointsInParallel; i++) {
        unsigned int x[N];
        readBigInt<N>(xAra, i, x);
        unsigned int rIdx = x[0] & R_POINT_MASK;

        unsigned int diff[N];
        unsigned int rx[N];
        getRX<N>(rIdx, rx);
        subModP<N>(x, rx, diff);

        writeBigInt<N>(diffBuf, i, diff);

        multiplyModP<N>(product, diff, product);
        writeBigInt<N>(chainBuf, i, product);
    }

    // Compute inverse
    unsigned int inverse[N];
    inverseModP<N>(product, inverse);

    // Extract inverse of the differences
    for(int i = pointsInParallel - 1; i >= 0; i--) {

        // Get the inverse of the last difference by multiplying the inverse of the product of all the differences
        // with the product of all but the last difference
        unsigned int invDiff[N];

        if(i >= 1) {
            unsigned int tmp[N];
            readBigInt<N>(chainBuf, i-1, tmp);
            multiplyModP<N>(inverse, tmp, invDiff);

            // Cancel out the last difference
            readBigInt<N>(diffBuf, i, tmp);
            multiplyModP<N>(inverse, tmp, inverse);

        } else {
            copy<N>(inverse, invDiff);
        }
        
        unsigned int px[N];
        unsigned int py[N];

        readBigInt<N>(xAra, i, px);
        readBigInt<N>(yAra, i, py);

        unsigned int rIdx = px[0] & R_POINT_MASK;
        unsigned int s[N];
        unsigned int s2[N];

        // s^2 = (Py - Qy / Px - Qx)^2
        unsigned int ry[N];
        getRY<N>(rIdx, ry);
        subModP<N>(py, ry, s);
        multiplyModP<N>(s, invDiff, s);
        squareModP<N>(s, s2);

        // Rx = s^2 - Px - Qx
        unsigned int newX[N];
        subModP<N>(s2, px, newX);

        unsigned int rx[N];
        getRX<N>(rIdx, rx);
        subModP<N>(newX, rx, newX);

        // Ry = -Py + s(Px - Rx)
        unsigned int k[N];
        subModP<N>(px, newX, k);
        multiplyModP<N>(k, s, k);
        unsigned int newY[N];
        subModP<N>(k, py, newY);

        // Write result to memory
        writeBigInt<N>(xAra, i, newX);
        writeBigInt<N>(yAra, i, newY);
       
        // Check for distinguished point, set flag if found
        if(((newX[ 0 ] & _MASK[ 0 ]) == 0) && ((newX[ 1 ] & _MASK[ 1 ]) == 0)) {
            blockFlags[blockIdx.x] = 1;
            pointFlags[gridDim.x * blockDim.x * i + blockIdx.x * blockDim.x + threadIdx.x] = 1;
        }
    }
}

template<int N> __global__ void doStepKernel( unsigned int *xAra,
                              unsigned int *yAra,
                              unsigned int *diffBuf,
                              unsigned int *chainBuf,
                              unsigned int *blockFlags,
                              unsigned int *pointFlags,
                              unsigned int pointsPerThread)
{
    // Initialize shared memory constants
    initFp();
    initSharedMem(_PWORDS);
    doStep<N>(xAra, yAra, diffBuf, chainBuf, blockFlags, pointFlags, pointsPerThread);
}

cudaError_t initDeviceConstants(unsigned int numPoints)
{
    cudaError_t cudaError = cudaSuccess;

    cudaError = cudaMemcpyToSymbol(_NUM_POINTS, &numPoints, sizeof(unsigned int), 0, cudaMemcpyHostToDevice);

    if(cudaError != cudaSuccess) {
        goto end;
    }

end:
    return cudaSuccess;
}

cudaError_t cudaDoStep(int pLen,
                    int blocks,
                    int threads,
                    int pointsPerThread,
                    unsigned int *rx,
                    unsigned int *ry,
                    unsigned int *diffBuf,
                    unsigned int *chainBuf,
                    unsigned int *blockFlags,
                    unsigned int *pointFlags)
{
    switch(pLen) {
        case 1:
            doStepKernel<1><<<blocks, threads>>>(rx, ry, diffBuf, chainBuf, blockFlags, pointFlags, pointsPerThread);
            break;
        case 2:
            doStepKernel<2><<<blocks, threads>>>(rx, ry, diffBuf, chainBuf, blockFlags, pointFlags, pointsPerThread);
            break;
        case 3:
            doStepKernel<3><<<blocks, threads>>>(rx, ry, diffBuf, chainBuf, blockFlags, pointFlags, pointsPerThread);
            break;
        case 4:
            doStepKernel<4><<<blocks, threads>>>(rx, ry, diffBuf, chainBuf, blockFlags, pointFlags, pointsPerThread);
            break;
        case 5:
            doStepKernel<5><<<blocks, threads>>>(rx, ry, diffBuf, chainBuf, blockFlags, pointFlags, pointsPerThread);
            break;
        case 6:
            doStepKernel<6><<<blocks, threads>>>(rx, ry, diffBuf, chainBuf, blockFlags, pointFlags, pointsPerThread);
            break;
        case 7:
            doStepKernel<7><<<blocks, threads>>>(rx, ry, diffBuf, chainBuf, blockFlags, pointFlags, pointsPerThread);
            break;
        case 8:
            doStepKernel<8><<<blocks, threads>>>(rx, ry, diffBuf, chainBuf, blockFlags, pointFlags, pointsPerThread);
            break;
        default:
            throw "Unsupported word size";

    }

    return cudaDeviceSynchronize();
}
