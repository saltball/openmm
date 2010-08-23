#define TILE_SIZE 32

typedef struct {
    float x, y, z;
    float q;
    float fx, fy, fz;
    ATOM_PARAMETER_DATA
} AtomData;

/**
 * Compute nonbonded interactions.
 */

__kernel __attribute__((reqd_work_group_size(WORK_GROUP_SIZE, 1, 1)))
void computeNonbonded(__global float4* forceBuffers, __global float* energyBuffer, __global float4* posq, __global unsigned int* exclusions,
        __global unsigned int* exclusionIndices, __global unsigned int* exclusionRowIndices, __local AtomData* localData, __local float4* tempBuffer,
#ifdef USE_CUTOFF
        __global ushort2* tiles, __global unsigned int* interactionCount, float4 periodicBoxSize, float4 invPeriodicBoxSize, __global unsigned int* interactionFlags
#else
        unsigned int numTiles
#endif
        PARAMETER_ARGUMENTS) {
    unsigned int totalWarps = get_global_size(0)/TILE_SIZE;
    unsigned int warp = get_global_id(0)/TILE_SIZE;
#ifdef USE_CUTOFF
    unsigned int numTiles = interactionCount[0];
    unsigned int pos = warp*(numTiles > MAX_TILES ? NUM_BLOCKS*(NUM_BLOCKS+1)/2 : numTiles)/totalWarps;
    unsigned int end = (warp+1)*(numTiles > MAX_TILES ? NUM_BLOCKS*(NUM_BLOCKS+1)/2 : numTiles)/totalWarps;
#else
    unsigned int pos = warp*numTiles/totalWarps;
    unsigned int end = (warp+1)*numTiles/totalWarps;
#endif
    float energy = 0.0f;
    unsigned int lasty = 0xFFFFFFFF;
    __local unsigned int exclusionRange[4];
    __local int exclusionIndex[2];

    while (pos < end) {
        // Extract the coordinates of this tile
        unsigned int x, y;
#ifdef USE_CUTOFF
        if (numTiles <= MAX_TILES) {
            ushort2 tileIndices = tiles[pos];
            x = tileIndices.x;
            y = tileIndices.y;
        }
        else
#endif
        {
            y = (unsigned int) floor(NUM_BLOCKS+0.5f-sqrt((NUM_BLOCKS+0.5f)*(NUM_BLOCKS+0.5f)-2*pos));
            x = (pos-y*NUM_BLOCKS+y*(y+1)/2);
            if (x >= NUM_BLOCKS) { // Occasionally happens due to roundoff error.
                y++;
                x = (pos-y*NUM_BLOCKS+y*(y+1)/2);
            }
        }
        unsigned int tgx = get_local_id(0) & (TILE_SIZE-1);
        unsigned int tbx = get_local_id(0) - tgx;
        unsigned int atom1 = x*TILE_SIZE + tgx;
        float4 force = 0.0f;
        float4 posq1 = posq[atom1];
        LOAD_ATOM1_PARAMETERS

        // Locate the exclusion data for this tile.

#ifdef USE_EXCLUSIONS
        int localGroupIndex = get_local_id(0)/TILE_SIZE;
        if (tgx < 2)
            exclusionRange[2*localGroupIndex+tgx] = exclusionRowIndices[x+tgx];
        if (tgx == 0)
            exclusionIndex[localGroupIndex] = -1;
        for (int i = exclusionRange[2*localGroupIndex]+tgx; i < exclusionRange[2*localGroupIndex+1]; i += TILE_SIZE)
            if (exclusionIndices[i] == y)
                exclusionIndex[localGroupIndex] = i*TILE_SIZE;
        bool hasExclusions = (exclusionIndex[localGroupIndex] > -1);
#else
        bool hasExclusions = false;
#endif
        if (x == y) {
            // This tile is on the diagonal.

            localData[get_local_id(0)].x = posq1.x;
            localData[get_local_id(0)].y = posq1.y;
            localData[get_local_id(0)].z = posq1.z;
            localData[get_local_id(0)].q = posq1.w;
            LOAD_LOCAL_PARAMETERS_FROM_1
#ifdef USE_EXCLUSIONS
            unsigned int excl = exclusions[exclusionIndex[localGroupIndex]+tgx];
#endif
            for (unsigned int j = 0; j < TILE_SIZE; j++) {
#ifdef USE_EXCLUSIONS
                bool isExcluded = !(excl & 0x1);
#endif
                int atom2 = tbx+j;
                float4 posq2 = (float4) (localData[atom2].x, localData[atom2].y, localData[atom2].z, localData[atom2].q);
                float4 delta = (float4) (posq2.xyz - posq1.xyz, 0.0f);
#ifdef USE_PERIODIC
                delta.x -= floor(delta.x*invPeriodicBoxSize.x+0.5f)*periodicBoxSize.x;
                delta.y -= floor(delta.y*invPeriodicBoxSize.y+0.5f)*periodicBoxSize.y;
                delta.z -= floor(delta.z*invPeriodicBoxSize.z+0.5f)*periodicBoxSize.z;
#endif
                float r2 = delta.x*delta.x + delta.y*delta.y + delta.z*delta.z;
                float r = sqrt(r2);
                float invR = RECIP(r);
                LOAD_ATOM2_PARAMETERS
                atom2 = y*TILE_SIZE+j;
#ifdef USE_SYMMETRIC
                float dEdR = 0.0f;
#else
                float4 dEdR1 = (float4) 0.0f;
                float4 dEdR2 = (float4) 0.0f;
#endif
                float tempEnergy = 0.0f;
                COMPUTE_INTERACTION
                energy += 0.5f*tempEnergy;
#ifdef USE_SYMMETRIC
                force.xyz -= delta.xyz*dEdR;
#else
                force.xyz -= dEdR1.xyz;
#endif
                excl >>= 1;
            }

            // Write results
#ifdef USE_OUTPUT_BUFFER_PER_BLOCK
            unsigned int offset = x*TILE_SIZE + tgx + x*PADDED_NUM_ATOMS;
#else
            unsigned int offset = x*TILE_SIZE + tgx + warp*PADDED_NUM_ATOMS;
#endif
            forceBuffers[offset].xyz += force.xyz;
        }
        else {
            // This is an off-diagonal tile.

            if (lasty != y) {
                unsigned int j = y*TILE_SIZE + tgx;
                float4 tempPosq = posq[j];
                localData[get_local_id(0)].x = tempPosq.x;
                localData[get_local_id(0)].y = tempPosq.y;
                localData[get_local_id(0)].z = tempPosq.z;
                localData[get_local_id(0)].q = tempPosq.w;
                LOAD_LOCAL_PARAMETERS_FROM_GLOBAL
            }
            localData[get_local_id(0)].fx = 0.0f;
            localData[get_local_id(0)].fy = 0.0f;
            localData[get_local_id(0)].fz = 0.0f;
#ifdef USE_CUTOFF
            unsigned int flags = (numTiles <= MAX_TILES ? interactionFlags[pos] : 0xFFFFFFFF);
            if (!hasExclusions && flags != 0xFFFFFFFF) {
                if (flags == 0) {
                    // No interactions in this tile.
                }
                else {
                    // Compute only a subset of the interactions in this tile.

                    for (unsigned int j = 0; j < TILE_SIZE; j++) {
                        if ((flags&(1<<j)) != 0) {
                            bool isExcluded = false;
                            int atom2 = tbx+j;
                            float4 posq2 = (float4) (localData[atom2].x, localData[atom2].y, localData[atom2].z, localData[atom2].q);
                            float4 delta = (float4) (posq2.xyz - posq1.xyz, 0.0f);
#ifdef USE_PERIODIC
                            delta.x -= floor(delta.x*invPeriodicBoxSize.x+0.5f)*periodicBoxSize.x;
                            delta.y -= floor(delta.y*invPeriodicBoxSize.y+0.5f)*periodicBoxSize.y;
                            delta.z -= floor(delta.z*invPeriodicBoxSize.z+0.5f)*periodicBoxSize.z;
#endif
                            float r2 = delta.x*delta.x + delta.y*delta.y + delta.z*delta.z;
                            float invR = RSQRT(r2);
                            float r = RECIP(invR);
                            LOAD_ATOM2_PARAMETERS
                            atom2 = y*TILE_SIZE+j;
#ifdef USE_SYMMETRIC
                            float dEdR = 0.0f;
#else
                            float4 dEdR1 = (float4) 0.0f;
                            float4 dEdR2 = (float4) 0.0f;
#endif
                            float tempEnergy = 0.0f;
                            COMPUTE_INTERACTION
			    energy += tempEnergy;
#ifdef USE_SYMMETRIC
                            delta.xyz *= dEdR;
                            force.xyz -= delta.xyz;
                            tempBuffer[get_local_id(0)] = delta;
#else
                            force.xyz -= dEdR1.xyz;
                            tempBuffer[get_local_id(0)] = dEdR2;
#endif

                            // Sum the forces on atom2.

                            if (tgx % 2 == 0)
                                tempBuffer[get_local_id(0)].xyz += tempBuffer[get_local_id(0)+1].xyz;
                            if (tgx % 4 == 0)
                                tempBuffer[get_local_id(0)].xyz += tempBuffer[get_local_id(0)+2].xyz;
                            if (tgx % 8 == 0)
                                tempBuffer[get_local_id(0)].xyz += tempBuffer[get_local_id(0)+4].xyz;
                            if (tgx % 16 == 0)
                                tempBuffer[get_local_id(0)].xyz += tempBuffer[get_local_id(0)+8].xyz;
                            if (tgx == 0) {
                                localData[tbx+j].fx += tempBuffer[get_local_id(0)].x + tempBuffer[get_local_id(0)+16].x;
                                localData[tbx+j].fy += tempBuffer[get_local_id(0)].y + tempBuffer[get_local_id(0)+16].y;
                                localData[tbx+j].fz += tempBuffer[get_local_id(0)].z + tempBuffer[get_local_id(0)+16].z;
                            }
                        }
                    }
                }
            }
            else
#endif
            {
                // Compute the full set of interactions in this tile.

#ifdef USE_EXCLUSIONS
                unsigned int excl = (hasExclusions ? exclusions[exclusionIndex[localGroupIndex]+tgx] : 0xFFFFFFFF);
                excl = (excl >> tgx) | (excl << (TILE_SIZE - tgx));
#endif
                unsigned int tj = tgx;
                for (unsigned int j = 0; j < TILE_SIZE; j++) {
#ifdef USE_EXCLUSIONS
                    bool isExcluded = !(excl & 0x1);
#endif
                    int atom2 = tbx+tj;
                    float4 posq2 = (float4) (localData[atom2].x, localData[atom2].y, localData[atom2].z, localData[atom2].q);
                    float4 delta = (float4) (posq2.xyz - posq1.xyz, 0.0f);
#ifdef USE_PERIODIC
                    delta.x -= floor(delta.x*invPeriodicBoxSize.x+0.5f)*periodicBoxSize.x;
                    delta.y -= floor(delta.y*invPeriodicBoxSize.y+0.5f)*periodicBoxSize.y;
                    delta.z -= floor(delta.z*invPeriodicBoxSize.z+0.5f)*periodicBoxSize.z;
#endif
                    float r2 = delta.x*delta.x + delta.y*delta.y + delta.z*delta.z;
                    float invR = RSQRT(r2);
                    float r = RECIP(invR);
                    LOAD_ATOM2_PARAMETERS
                    atom2 = y*TILE_SIZE+tj;
#ifdef USE_SYMMETRIC
                    float dEdR = 0.0f;
#else
                    float4 dEdR1 = (float4) 0.0f;
                    float4 dEdR2 = (float4) 0.0f;
#endif
                    float tempEnergy = 0.0f;
                    COMPUTE_INTERACTION
		    energy += tempEnergy;
#ifdef USE_SYMMETRIC
                    delta.xyz *= dEdR;
                    force.xyz -= delta.xyz;
                    localData[tbx+tj].fx += delta.x;
                    localData[tbx+tj].fy += delta.y;
                    localData[tbx+tj].fz += delta.z;
#else
                    force.xyz -= dEdR1.xyz;
                    localData[tbx+tj].fx += dEdR2.x;
                    localData[tbx+tj].fy += dEdR2.y;
                    localData[tbx+tj].fz += dEdR2.z;
#endif
                    excl >>= 1;
                    tj = (tj + 1) & (TILE_SIZE - 1);
                }
            }

            // Write results
#ifdef USE_OUTPUT_BUFFER_PER_BLOCK
            unsigned int offset1 = x*TILE_SIZE + tgx + y*PADDED_NUM_ATOMS;
            unsigned int offset2 = y*TILE_SIZE + tgx + x*PADDED_NUM_ATOMS;
#else
            unsigned int offset1 = x*TILE_SIZE + tgx + warp*PADDED_NUM_ATOMS;
            unsigned int offset2 = y*TILE_SIZE + tgx + warp*PADDED_NUM_ATOMS;
#endif
            forceBuffers[offset1].xyz += force.xyz;
            forceBuffers[offset2] += (float4) (localData[get_local_id(0)].fx, localData[get_local_id(0)].fy, localData[get_local_id(0)].fz, 0.0f);
        }
        lasty = y;
        pos++;
    }
    energyBuffer[get_global_id(0)] += energy;
}
