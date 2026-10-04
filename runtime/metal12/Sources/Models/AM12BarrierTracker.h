/*
 * Alloy Metal12 reusable barrier access and hazard planner.
 * Author: Timur Isaev
 */

#ifndef AM12_BARRIER_TRACKER_H
#define AM12_BARRIER_TRACKER_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C"
{
#endif

#define AM12_BARRIER_ALL_SUBRESOURCES (-1)

    typedef enum AM12BarrierAccessKind
    {
        AM12_BARRIER_ACCESS_READ = 0,
        AM12_BARRIER_ACCESS_WRITE = 1,
        AM12_BARRIER_ACCESS_TRANSITION = 2,
    } AM12BarrierAccessKind;

    typedef struct AM12BarrierAccess
    {
        uint32_t queue;
        uint32_t memory_object;
        int32_t subresource;
        AM12BarrierAccessKind kind;
        uint32_t queue_position;
    } AM12BarrierAccess;

    typedef struct AM12BarrierEdge
    {
        uint32_t from_access;
        uint32_t to_access;
    } AM12BarrierEdge;

    typedef struct AM12BarrierPlan
    {
        AM12BarrierEdge *edges;
        uint32_t edge_count;
        uint32_t edge_capacity;
    } AM12BarrierPlan;

    typedef struct AM12BarrierVerification
    {
        uint64_t hazard_count;
        uint64_t uncovered_hazard_count;
    } AM12BarrierVerification;

    typedef struct AM12BarrierTrackerDescriptor
    {
        uint32_t max_access_count;
        uint32_t memory_object_count;
        uint32_t subresource_count;
        uint32_t queue_count;
    } AM12BarrierTrackerDescriptor;

    typedef struct AM12BarrierTracker AM12BarrierTracker;

    AM12BarrierTracker *AM12BarrierTrackerCreate(const AM12BarrierTrackerDescriptor *descriptor);
    void AM12BarrierTrackerDestroy(AM12BarrierTracker *tracker);

    /*
     * Clears the recorded access stream and per-queue positions. Resource states
     * are deliberately retained so a runtime may plan one submission at a time.
     */
    void AM12BarrierTrackerResetAccesses(AM12BarrierTracker *tracker);

    uint32_t AM12BarrierTrackerAccessCount(const AM12BarrierTracker *tracker);
    const AM12BarrierAccess *AM12BarrierTrackerAccessAt(const AM12BarrierTracker *tracker,
                                                        uint32_t access_index);
    int AM12BarrierTrackerRecordAccess(AM12BarrierTracker *tracker, uint32_t queue,
                                       uint32_t memory_object, int32_t subresource,
                                       AM12BarrierAccessKind kind, uint32_t *access_index);
    /*
     * Validates the complete batch before appending any access. queue_position
     * fields in the input are ignored and assigned by the tracker.
     */
    int AM12BarrierTrackerRecordAccessBatch(AM12BarrierTracker *tracker,
                                            const AM12BarrierAccess *accesses,
                                            uint32_t access_count, uint32_t *first_access_index);

    /*
     * Generic state storage lets the command layer validate transitions through
     * the same model without coupling this private component to public API enums.
     * Whole-resource operations require all subresources to have the same state.
     */
    void AM12BarrierTrackerResetStates(AM12BarrierTracker *tracker);
    int AM12BarrierTrackerSetState(AM12BarrierTracker *tracker, uint32_t memory_object,
                                   int32_t subresource, uint32_t state);
    int AM12BarrierTrackerGetState(const AM12BarrierTracker *tracker, uint32_t memory_object,
                                   int32_t subresource, uint32_t *state);
    int AM12BarrierTrackerApplyTransition(AM12BarrierTracker *tracker, uint32_t memory_object,
                                          int32_t subresource, uint32_t before, uint32_t after);

    int AM12BarrierAccessesOverlap(const AM12BarrierAccess *earlier,
                                   const AM12BarrierAccess *later);
    int AM12BarrierAccessesHazard(const AM12BarrierAccess *earlier, const AM12BarrierAccess *later);

    int AM12BarrierPlanInitialize(AM12BarrierPlan *plan, AM12BarrierEdge *edge_storage,
                                  uint32_t edge_capacity);
    void AM12BarrierPlanReset(AM12BarrierPlan *plan);
    int AM12BarrierPlanCopy(AM12BarrierPlan *destination, const AM12BarrierPlan *source);
    int AM12BarrierPlanRemoveEdgeSwapLast(AM12BarrierPlan *plan, uint32_t edge_index);

    int AM12BarrierTrackerCompileConservative(AM12BarrierTracker *tracker, AM12BarrierPlan *plan);
    int AM12BarrierTrackerCompileOptimized(AM12BarrierTracker *tracker, AM12BarrierPlan *plan);
    int AM12BarrierTrackerVerifyPlan(AM12BarrierTracker *tracker, const AM12BarrierPlan *plan,
                                     AM12BarrierVerification *verification);

#ifdef __cplusplus
}
#endif

#endif
