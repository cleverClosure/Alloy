/*
 * Alloy Metal12 reusable barrier access and hazard planner.
 * Author: Timur Isaev
 *
 * Promoted from the first-party M12-002 model under ADR-0012.
 */

#include "AM12BarrierTracker.h"

#include <limits.h>
#include <stdlib.h>
#include <string.h>

struct AM12BarrierTracker
{
    AM12BarrierTrackerDescriptor descriptor;
    AM12BarrierAccess *accesses;
    uint32_t access_count;
    uint32_t *queue_positions;

    uint32_t *states;
    uint8_t *state_initialized;

    int32_t *last_writes;
    uint32_t *reader_counts;
    uint32_t *readers;
    uint32_t track_slot_count;

    uint64_t *compile_reach;
    uint64_t *verify_reach;
    uint32_t reach_word_count;

    int32_t *predecessor_heads;
    int32_t *predecessor_next;
    uint32_t *predecessor_from;
    uint32_t maximum_edge_count;

    uint32_t *candidates;
    uint32_t candidate_capacity;
};

static int AM12BarrierCheckedMultiplySize(size_t left, size_t right, size_t *result)
{
    if (left && right > SIZE_MAX / left)
        return 0;
    *result = left * right;
    return 1;
}

static int AM12BarrierCheckedMultiplyU64(uint64_t left, uint64_t right, uint64_t *result)
{
    if (left && right > UINT64_MAX / left)
        return 0;
    *result = left * right;
    return 1;
}

static void *AM12BarrierAllocateArray(size_t count, size_t element_size)
{
    size_t bytes = 0;

    if (!count || !element_size || !AM12BarrierCheckedMultiplySize(count, element_size, &bytes))
        return NULL;
    return calloc(1, bytes);
}

static int AM12BarrierSubresourceValid(const AM12BarrierTracker *tracker, int32_t subresource)
{
    return tracker &&
           (subresource == AM12_BARRIER_ALL_SUBRESOURCES ||
            (subresource >= 0 && (uint32_t)subresource < tracker->descriptor.subresource_count));
}

static size_t AM12BarrierStateIndex(const AM12BarrierTracker *tracker, uint32_t memory_object,
                                    uint32_t subresource)
{
    return (size_t)memory_object * tracker->descriptor.subresource_count + subresource;
}

AM12BarrierTracker *AM12BarrierTrackerCreate(const AM12BarrierTrackerDescriptor *descriptor)
{
    if (!descriptor || !descriptor->max_access_count || !descriptor->memory_object_count ||
        !descriptor->subresource_count || !descriptor->queue_count ||
        descriptor->subresource_count > INT32_MAX)
        return NULL;

    uint64_t laneCount = (uint64_t)descriptor->subresource_count + 1u;
    uint64_t maximumEdges = 0;
    uint64_t trackSlots = 0;
    uint64_t stateSlots = 0;
    uint64_t reachWords = ((uint64_t)descriptor->max_access_count + 63u) / 64u;
    uint64_t reachSlots = 0;
    uint64_t readerSlots = 0;
    uint64_t candidateCapacity = 0;

    if (!AM12BarrierCheckedMultiplyU64(descriptor->max_access_count, descriptor->max_access_count,
                                       &maximumEdges) ||
        !AM12BarrierCheckedMultiplyU64(descriptor->memory_object_count, laneCount, &trackSlots) ||
        !AM12BarrierCheckedMultiplyU64(descriptor->memory_object_count,
                                       descriptor->subresource_count, &stateSlots) ||
        !AM12BarrierCheckedMultiplyU64(descriptor->max_access_count, reachWords, &reachSlots) ||
        maximumEdges > INT32_MAX || trackSlots > UINT32_MAX || stateSlots > SIZE_MAX ||
        reachWords > UINT32_MAX || reachSlots > SIZE_MAX)
        return NULL;
    if (!AM12BarrierCheckedMultiplyU64(trackSlots, descriptor->max_access_count, &readerSlots) ||
        !AM12BarrierCheckedMultiplyU64(laneCount, (uint64_t)descriptor->max_access_count + 1u,
                                       &candidateCapacity) ||
        readerSlots > SIZE_MAX || candidateCapacity > UINT32_MAX)
        return NULL;

    AM12BarrierTracker *tracker = calloc(1, sizeof(*tracker));
    if (!tracker)
        return NULL;
    tracker->descriptor = *descriptor;
    tracker->maximum_edge_count = (uint32_t)maximumEdges;
    tracker->track_slot_count = (uint32_t)trackSlots;
    tracker->reach_word_count = (uint32_t)reachWords;
    tracker->candidate_capacity = (uint32_t)candidateCapacity;

    tracker->accesses =
        AM12BarrierAllocateArray(descriptor->max_access_count, sizeof(*tracker->accesses));
    tracker->queue_positions =
        AM12BarrierAllocateArray(descriptor->queue_count, sizeof(*tracker->queue_positions));
    tracker->states = AM12BarrierAllocateArray((size_t)stateSlots, sizeof(*tracker->states));
    tracker->state_initialized =
        AM12BarrierAllocateArray((size_t)stateSlots, sizeof(*tracker->state_initialized));
    tracker->last_writes =
        AM12BarrierAllocateArray(tracker->track_slot_count, sizeof(*tracker->last_writes));
    tracker->reader_counts =
        AM12BarrierAllocateArray(tracker->track_slot_count, sizeof(*tracker->reader_counts));
    tracker->readers = AM12BarrierAllocateArray((size_t)readerSlots, sizeof(*tracker->readers));
    tracker->compile_reach =
        AM12BarrierAllocateArray((size_t)reachSlots, sizeof(*tracker->compile_reach));
    tracker->verify_reach =
        AM12BarrierAllocateArray((size_t)reachSlots, sizeof(*tracker->verify_reach));
    tracker->predecessor_heads =
        AM12BarrierAllocateArray(descriptor->max_access_count, sizeof(*tracker->predecessor_heads));
    tracker->predecessor_next =
        AM12BarrierAllocateArray(tracker->maximum_edge_count, sizeof(*tracker->predecessor_next));
    tracker->predecessor_from =
        AM12BarrierAllocateArray(tracker->maximum_edge_count, sizeof(*tracker->predecessor_from));
    tracker->candidates =
        AM12BarrierAllocateArray(tracker->candidate_capacity, sizeof(*tracker->candidates));

    if (!tracker->accesses || !tracker->queue_positions || !tracker->states ||
        !tracker->state_initialized || !tracker->last_writes || !tracker->reader_counts ||
        !tracker->readers || !tracker->compile_reach || !tracker->verify_reach ||
        !tracker->predecessor_heads || !tracker->predecessor_next || !tracker->predecessor_from ||
        !tracker->candidates)
    {
        AM12BarrierTrackerDestroy(tracker);
        return NULL;
    }
    return tracker;
}

void AM12BarrierTrackerDestroy(AM12BarrierTracker *tracker)
{
    if (!tracker)
        return;
    free(tracker->accesses);
    free(tracker->queue_positions);
    free(tracker->states);
    free(tracker->state_initialized);
    free(tracker->last_writes);
    free(tracker->reader_counts);
    free(tracker->readers);
    free(tracker->compile_reach);
    free(tracker->verify_reach);
    free(tracker->predecessor_heads);
    free(tracker->predecessor_next);
    free(tracker->predecessor_from);
    free(tracker->candidates);
    free(tracker);
}

void AM12BarrierTrackerResetAccesses(AM12BarrierTracker *tracker)
{
    if (!tracker)
        return;
    tracker->access_count = 0;
    memset(tracker->queue_positions, 0,
           (size_t)tracker->descriptor.queue_count * sizeof(*tracker->queue_positions));
}

uint32_t AM12BarrierTrackerAccessCount(const AM12BarrierTracker *tracker)
{
    return tracker ? tracker->access_count : 0;
}

const AM12BarrierAccess *AM12BarrierTrackerAccessAt(const AM12BarrierTracker *tracker,
                                                    uint32_t access_index)
{
    if (!tracker || access_index >= tracker->access_count)
        return NULL;
    return &tracker->accesses[access_index];
}

int AM12BarrierTrackerRecordAccess(AM12BarrierTracker *tracker, uint32_t queue,
                                   uint32_t memory_object, int32_t subresource,
                                   AM12BarrierAccessKind kind, uint32_t *access_index)
{
    AM12BarrierAccess access = {
        .queue = queue,
        .memory_object = memory_object,
        .subresource = subresource,
        .kind = kind,
    };
    return AM12BarrierTrackerRecordAccessBatch(tracker, &access, 1, access_index);
}

int AM12BarrierTrackerRecordAccessBatch(AM12BarrierTracker *tracker,
                                        const AM12BarrierAccess *accesses, uint32_t access_count,
                                        uint32_t *first_access_index)
{
    if (!tracker || !accesses || !access_count ||
        access_count > tracker->descriptor.max_access_count - tracker->access_count)
        return 0;

    for (uint32_t index = 0; index < access_count; index++)
    {
        const AM12BarrierAccess *access = &accesses[index];
        if (access->queue >= tracker->descriptor.queue_count ||
            access->memory_object >= tracker->descriptor.memory_object_count ||
            !AM12BarrierSubresourceValid(tracker, access->subresource) ||
            (access->kind != AM12_BARRIER_ACCESS_READ &&
             access->kind != AM12_BARRIER_ACCESS_WRITE &&
             access->kind != AM12_BARRIER_ACCESS_TRANSITION))
            return 0;
    }

    uint32_t first = tracker->access_count;
    for (uint32_t index = 0; index < access_count; index++)
    {
        AM12BarrierAccess access = accesses[index];
        access.queue_position = tracker->queue_positions[access.queue]++;
        tracker->accesses[tracker->access_count++] = access;
    }
    if (first_access_index)
        *first_access_index = first;
    return 1;
}

void AM12BarrierTrackerResetStates(AM12BarrierTracker *tracker)
{
    if (!tracker)
        return;
    size_t count =
        (size_t)tracker->descriptor.memory_object_count * tracker->descriptor.subresource_count;
    memset(tracker->state_initialized, 0, count * sizeof(*tracker->state_initialized));
}

int AM12BarrierTrackerSetState(AM12BarrierTracker *tracker, uint32_t memory_object,
                               int32_t subresource, uint32_t state)
{
    if (!tracker || memory_object >= tracker->descriptor.memory_object_count ||
        !AM12BarrierSubresourceValid(tracker, subresource))
        return 0;

    uint32_t first = subresource < 0 ? 0u : (uint32_t)subresource;
    uint32_t end =
        subresource < 0 ? tracker->descriptor.subresource_count : (uint32_t)subresource + 1u;
    for (uint32_t slot = first; slot < end; slot++)
    {
        size_t index = AM12BarrierStateIndex(tracker, memory_object, slot);
        tracker->states[index] = state;
        tracker->state_initialized[index] = 1;
    }
    return 1;
}

int AM12BarrierTrackerGetState(const AM12BarrierTracker *tracker, uint32_t memory_object,
                               int32_t subresource, uint32_t *state)
{
    if (!tracker || !state || memory_object >= tracker->descriptor.memory_object_count ||
        !AM12BarrierSubresourceValid(tracker, subresource))
        return 0;

    uint32_t first = subresource < 0 ? 0u : (uint32_t)subresource;
    uint32_t end =
        subresource < 0 ? tracker->descriptor.subresource_count : (uint32_t)subresource + 1u;
    size_t firstIndex = AM12BarrierStateIndex(tracker, memory_object, first);
    if (!tracker->state_initialized[firstIndex])
        return 0;
    uint32_t result = tracker->states[firstIndex];
    for (uint32_t slot = first + 1u; slot < end; slot++)
    {
        size_t index = AM12BarrierStateIndex(tracker, memory_object, slot);
        if (!tracker->state_initialized[index] || tracker->states[index] != result)
            return 0;
    }
    *state = result;
    return 1;
}

int AM12BarrierTrackerApplyTransition(AM12BarrierTracker *tracker, uint32_t memory_object,
                                      int32_t subresource, uint32_t before, uint32_t after)
{
    uint32_t current = 0;

    if (!AM12BarrierTrackerGetState(tracker, memory_object, subresource, &current) ||
        current != before)
        return 0;
    return AM12BarrierTrackerSetState(tracker, memory_object, subresource, after);
}

int AM12BarrierAccessesOverlap(const AM12BarrierAccess *earlier, const AM12BarrierAccess *later)
{
    if (!earlier || !later || earlier->memory_object != later->memory_object)
        return 0;
    return earlier->subresource < 0 || later->subresource < 0 ||
           earlier->subresource == later->subresource;
}

int AM12BarrierAccessesHazard(const AM12BarrierAccess *earlier, const AM12BarrierAccess *later)
{
    if (!AM12BarrierAccessesOverlap(earlier, later))
        return 0;
    return earlier->kind != AM12_BARRIER_ACCESS_READ || later->kind != AM12_BARRIER_ACCESS_READ;
}

int AM12BarrierPlanInitialize(AM12BarrierPlan *plan, AM12BarrierEdge *edge_storage,
                              uint32_t edge_capacity)
{
    if (!plan || !edge_storage || !edge_capacity)
        return 0;
    *plan = (AM12BarrierPlan){
        .edges = edge_storage,
        .edge_count = 0,
        .edge_capacity = edge_capacity,
    };
    return 1;
}

void AM12BarrierPlanReset(AM12BarrierPlan *plan)
{
    if (plan)
        plan->edge_count = 0;
}

int AM12BarrierPlanCopy(AM12BarrierPlan *destination, const AM12BarrierPlan *source)
{
    if (!destination || !source || !destination->edges || !source->edges ||
        source->edge_count > source->edge_capacity ||
        source->edge_count > destination->edge_capacity)
        return 0;
    memmove(destination->edges, source->edges, (size_t)source->edge_count * sizeof(*source->edges));
    destination->edge_count = source->edge_count;
    return 1;
}

int AM12BarrierPlanRemoveEdgeSwapLast(AM12BarrierPlan *plan, uint32_t edge_index)
{
    if (!plan || !plan->edges || edge_index >= plan->edge_count)
        return 0;
    plan->edges[edge_index] = plan->edges[--plan->edge_count];
    return 1;
}

static int AM12BarrierPlanAppendEdge(AM12BarrierPlan *plan, uint32_t from_access,
                                     uint32_t to_access)
{
    if (!plan || !plan->edges || plan->edge_count >= plan->edge_capacity)
        return 0;
    plan->edges[plan->edge_count++] = (AM12BarrierEdge){
        .from_access = from_access,
        .to_access = to_access,
    };
    return 1;
}

int AM12BarrierTrackerCompileConservative(AM12BarrierTracker *tracker, AM12BarrierPlan *plan)
{
    if (!tracker || !plan || !plan->edges || !plan->edge_capacity)
        return 0;
    AM12BarrierPlanReset(plan);
    for (uint32_t later = 0; later < tracker->access_count; later++)
        for (uint32_t earlier = 0; earlier < later; earlier++)
            if (tracker->accesses[earlier].memory_object ==
                    tracker->accesses[later].memory_object &&
                !AM12BarrierPlanAppendEdge(plan, earlier, later))
                return 0;
    return 1;
}

static uint64_t *AM12BarrierReachRow(uint64_t *reach, uint32_t word_count, uint32_t access)
{
    return reach + (size_t)access * word_count;
}

static int AM12BarrierAppendCandidate(AM12BarrierTracker *tracker, uint32_t *candidate_count,
                                      uint32_t access)
{
    if (*candidate_count >= tracker->candidate_capacity)
        return 0;
    tracker->candidates[(*candidate_count)++] = access;
    return 1;
}

int AM12BarrierTrackerCompileOptimized(AM12BarrierTracker *tracker, AM12BarrierPlan *plan)
{
    if (!tracker || !plan || !plan->edges || !plan->edge_capacity)
        return 0;
    AM12BarrierPlanReset(plan);
    memset(tracker->compile_reach, 0,
           (size_t)tracker->descriptor.max_access_count * tracker->reach_word_count *
               sizeof(*tracker->compile_reach));
    for (uint32_t slot = 0; slot < tracker->track_slot_count; slot++)
    {
        tracker->last_writes[slot] = -1;
        tracker->reader_counts[slot] = 0;
    }

    uint32_t laneCount = tracker->descriptor.subresource_count + 1u;
    for (uint32_t later = 0; later < tracker->access_count; later++)
    {
        const AM12BarrierAccess *access = &tracker->accesses[later];
        uint32_t first = access->subresource < 0 ? 0u : (uint32_t)access->subresource;
        uint32_t last = access->subresource < 0 ? tracker->descriptor.subresource_count
                                                : (uint32_t)access->subresource;
        uint32_t candidateCount = 0;

        for (uint32_t subresource = first; subresource <= last; subresource++)
        {
            uint32_t trackIndex = access->memory_object * laneCount + subresource;
            int32_t lastWrite = tracker->last_writes[trackIndex];
            uint32_t readerCount = tracker->reader_counts[trackIndex];
            uint32_t *readers =
                tracker->readers + (size_t)trackIndex * tracker->descriptor.max_access_count;

            if (access->kind == AM12_BARRIER_ACCESS_READ)
            {
                if (lastWrite >= 0 &&
                    !AM12BarrierAppendCandidate(tracker, &candidateCount, (uint32_t)lastWrite))
                    return 0;
            }
            else
            {
                if (lastWrite >= 0 &&
                    !AM12BarrierAppendCandidate(tracker, &candidateCount, (uint32_t)lastWrite))
                    return 0;
                for (uint32_t reader = 0; reader < readerCount; reader++)
                    if (!AM12BarrierAppendCandidate(tracker, &candidateCount, readers[reader]))
                        return 0;
            }
        }

        for (uint32_t left = 0; left < candidateCount; left++)
            for (uint32_t right = left + 1u; right < candidateCount; right++)
                if (tracker->candidates[right] > tracker->candidates[left])
                {
                    uint32_t temporary = tracker->candidates[left];
                    tracker->candidates[left] = tracker->candidates[right];
                    tracker->candidates[right] = temporary;
                }

        uint64_t *laterReach =
            AM12BarrierReachRow(tracker->compile_reach, tracker->reach_word_count, later);
        for (uint32_t candidate = 0; candidate < candidateCount; candidate++)
        {
            uint32_t earlier = tracker->candidates[candidate];
            if (candidate && earlier == tracker->candidates[candidate - 1u])
                continue;
            if ((laterReach[earlier / 64u] >> (earlier % 64u)) & 1u)
                continue;
            if (!AM12BarrierPlanAppendEdge(plan, earlier, later))
                return 0;
            uint64_t *earlierReach =
                AM12BarrierReachRow(tracker->compile_reach, tracker->reach_word_count, earlier);
            for (uint32_t word = 0; word < tracker->reach_word_count; word++)
                laterReach[word] |= earlierReach[word];
            laterReach[earlier / 64u] |= UINT64_C(1) << (earlier % 64u);
        }

        for (uint32_t subresource = first; subresource <= last; subresource++)
        {
            uint32_t trackIndex = access->memory_object * laneCount + subresource;
            uint32_t *readers =
                tracker->readers + (size_t)trackIndex * tracker->descriptor.max_access_count;

            if (access->kind == AM12_BARRIER_ACCESS_READ)
            {
                uint32_t readerCount = tracker->reader_counts[trackIndex];
                if (readerCount >= tracker->descriptor.max_access_count)
                    return 0;
                readers[readerCount] = later;
                tracker->reader_counts[trackIndex] = readerCount + 1u;
            }
            else
            {
                tracker->last_writes[trackIndex] = (int32_t)later;
                tracker->reader_counts[trackIndex] = 0;
            }
        }
    }
    return 1;
}

int AM12BarrierTrackerVerifyPlan(AM12BarrierTracker *tracker, const AM12BarrierPlan *plan,
                                 AM12BarrierVerification *verification)
{
    if (!tracker || !plan || !verification || !plan->edges ||
        plan->edge_count > plan->edge_capacity || plan->edge_count > tracker->maximum_edge_count)
        return 0;

    memset(tracker->verify_reach, 0,
           (size_t)tracker->descriptor.max_access_count * tracker->reach_word_count *
               sizeof(*tracker->verify_reach));
    memset(tracker->predecessor_heads, 0xff,
           (size_t)tracker->descriptor.max_access_count * sizeof(*tracker->predecessor_heads));
    for (uint32_t edge = 0; edge < plan->edge_count; edge++)
    {
        uint32_t from = plan->edges[edge].from_access;
        uint32_t to = plan->edges[edge].to_access;
        if (from >= tracker->access_count || to >= tracker->access_count || from >= to)
            return 0;
        tracker->predecessor_from[edge] = from;
        tracker->predecessor_next[edge] = tracker->predecessor_heads[to];
        tracker->predecessor_heads[to] = (int32_t)edge;
    }

    for (uint32_t later = 0; later < tracker->access_count; later++)
    {
        uint64_t *laterReach =
            AM12BarrierReachRow(tracker->verify_reach, tracker->reach_word_count, later);
        for (int32_t edge = tracker->predecessor_heads[later]; edge >= 0;
             edge = tracker->predecessor_next[edge])
        {
            uint32_t earlier = tracker->predecessor_from[edge];
            uint64_t *earlierReach =
                AM12BarrierReachRow(tracker->verify_reach, tracker->reach_word_count, earlier);
            for (uint32_t word = 0; word < tracker->reach_word_count; word++)
                laterReach[word] |= earlierReach[word];
            laterReach[earlier / 64u] |= UINT64_C(1) << (earlier % 64u);
        }
    }

    AM12BarrierVerification result = {0};
    for (uint32_t later = 0; later < tracker->access_count; later++)
    {
        const uint64_t *laterReach =
            AM12BarrierReachRow(tracker->verify_reach, tracker->reach_word_count, later);
        for (uint32_t earlier = 0; earlier < later; earlier++)
            if (AM12BarrierAccessesHazard(&tracker->accesses[earlier], &tracker->accesses[later]))
            {
                result.hazard_count++;
                if (!((laterReach[earlier / 64u] >> (earlier % 64u)) & 1u))
                    result.uncovered_hazard_count++;
            }
    }
    *verification = result;
    return 1;
}
