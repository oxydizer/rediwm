//! Indexed min-heap for the folder-size cache eviction candidates.
const std = @import("std");

pub const not_indexed = std.math.maxInt(usize);

pub fn Heap(
    comptime Item: type,
    comptime Context: type,
    comptime indexOf: fn (Context, Item) *usize,
    comptime older: fn (Context, Item, Item) bool,
) type {
    return struct {
        pub fn insert(items: *std.ArrayList(Item), ctx: Context, item: Item) void {
            const index = items.items.len;
            items.appendAssumeCapacity(item);
            indexOf(ctx, item).* = index;
            siftUp(items.items, ctx, index);
        }

        pub fn remove(items: *std.ArrayList(Item), ctx: Context, item: Item) void {
            const index = indexOf(ctx, item);
            const at = index.*;
            if (at == not_indexed) return;
            index.* = not_indexed;
            const last = items.pop().?;
            const heap = items.items;
            if (at == heap.len) return;
            heap[at] = last;
            indexOf(ctx, last).* = at;
            if (at > 0 and older(ctx, last, heap[(at - 1) / 2])) {
                siftUp(heap, ctx, at);
            } else {
                siftDown(heap, ctx, at);
            }
        }

        pub fn refreshed(items: []Item, ctx: Context, item: Item) void {
            const index = indexOf(ctx, item).*;
            if (index != not_indexed) siftDown(items, ctx, index);
        }

        fn swap(items: []Item, ctx: Context, a: usize, b: usize) void {
            std.mem.swap(Item, &items[a], &items[b]);
            indexOf(ctx, items[a]).* = a;
            indexOf(ctx, items[b]).* = b;
        }

        fn siftUp(items: []Item, ctx: Context, start: usize) void {
            var index = start;
            while (index > 0) {
                const parent = (index - 1) / 2;
                if (!older(ctx, items[index], items[parent])) break;
                swap(items, ctx, index, parent);
                index = parent;
            }
        }

        fn siftDown(items: []Item, ctx: Context, start: usize) void {
            var index = start;
            while (index < items.len / 2) {
                const left = 2 * index + 1;
                const right = left + 1;
                const oldest = if (right < items.len and older(ctx, items[right], items[left])) right else left;
                if (!older(ctx, items[oldest], items[index])) break;
                swap(items, ctx, index, oldest);
                index = oldest;
            }
        }
    };
}
