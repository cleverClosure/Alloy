/*
 * Metal12 linked DXIL-to-MSL command-line client.
 * Author: Timur Isaev
 */

#import "../include/AlloyMetal12.h"

#include <stdio.h>

int main(int argc, const char *argv[])
{
    if (argc != 4)
    {
        fprintf(stderr, "usage: %s INPUT.DXIL INPUT.LL OUTPUT_DIRECTORY\n", argv[0]);
        return 2;
    }

    AM12ShaderLoweringRequest request = {
        .dxil_path = argv[1],
        .disassembly_path = argv[2],
        .output_directory = argv[3],
    };
    return AM12LowerDXILToMSL(&request) ? 0 : 1;
}
