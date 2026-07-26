/*
 * Metal12 shader-proof support.
 * Author: Timur Isaev
 */

#import "AlloyMetal12.h"

int AM12ValidateShaderProofConfiguration(const AM12ShaderProofConfiguration *configuration)
{
    if (!configuration || configuration->thread_count == 0 ||
        configuration->threads_per_threadgroup == 0 || configuration->thread_execution_width == 0 ||
        configuration->thread_count % configuration->threads_per_threadgroup != 0 ||
        configuration->threads_per_threadgroup % configuration->thread_execution_width != 0)
        return 0;

    const int hasTexture = configuration->texture_width != 0 ||
                           configuration->texture_height != 0 ||
                           configuration->texture_mip_levels != 0;
    if (!hasTexture)
        return 1;
    if (configuration->texture_width == 0 || configuration->texture_height == 0 ||
        configuration->texture_mip_levels == 0)
        return 0;

    uint32_t maximumDimension = configuration->texture_width;
    if (configuration->texture_height > maximumDimension)
        maximumDimension = configuration->texture_height;

    uint32_t maximumMipLevels = 1;
    while (maximumDimension > 1)
    {
        maximumDimension >>= 1;
        maximumMipLevels++;
    }
    return configuration->texture_mip_levels <= maximumMipLevels;
}
