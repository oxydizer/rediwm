//! Allocation-free scan scheduling under the service mutex.
const c = @import("c.zig").api;
const tree = @import("sizetree.zig");
const Service = tree.Service;
const Id = tree.Id;
const no_id = tree.no_id;
const Level = tree.Level;

pub const Queue = struct {
    first: Id = no_id,
    last: Id = no_id,
};

pub fn unqueue(self: *Service, id: Id) void {
    const node = &self.nodes.items[id];
    const level = node.queued orelse return;
    const queue = &self.queues[@backingInt(level)];
    if (node.queue_prev == no_id) {
        queue.first = node.queue_next;
    } else {
        self.nodes.items[node.queue_prev].queue_next = node.queue_next;
    }
    if (node.queue_next == no_id) {
        queue.last = node.queue_prev;
    } else {
        self.nodes.items[node.queue_next].queue_prev = node.queue_prev;
    }
    node.queue_prev = no_id;
    node.queue_next = no_id;
    node.queued = null;
    self.queued_count -= 1;
}

pub fn enqueue(self: *Service, id: Id, level: Level) void {
    const node = &self.nodes.items[id];
    if (node.paused) return;
    if (node.scanning) {
        node.rescan = node.rescan or !node.self_pending;
        if (@backingInt(level) < @backingInt(node.level)) node.level = level;
        return;
    }
    if (node.queued) |q| if (@backingInt(q) <= @backingInt(level)) return;
    self.unqueue(id);
    const queue = &self.queues[@backingInt(level)];
    node.queue_prev = queue.last;
    if (queue.last == no_id) {
        queue.first = id;
    } else {
        self.nodes.items[queue.last].queue_next = id;
    }
    queue.last = id;
    node.queued = level;
    node.level = level;
    self.queued_count += 1;
    _ = c.pthread_cond_signal(&self.cond);
}

/// Same reverse child order as pushing children onto a stack, using the
/// child's slot in its parent's list to find the next sibling.
pub fn next(self: *Service, root: Id, from: Id, descend: bool) Id {
    if (descend) if (self.nodes.items[from].children.getLastOrNull()) |child| return child;
    var id = from;
    while (id != root) {
        const node = &self.nodes.items[id];
        if (node.child_index != 0)
            return self.nodes.items[node.parent].children.items[node.child_index - 1];
        id = node.parent;
    }
    return no_id;
}

/// Marks every directory below root to be read again, keeping totals.
pub fn markSubtree(self: *Service, root: Id) void {
    var id = root;
    while (id != no_id) : (id = next(self, root, id, true)) {
        const node = &self.nodes.items[id];
        if (node.paused) continue;
        if (!node.self_pending) {
            node.self_pending = true;
            self.propagate(id, 0, 1, 0);
        }
        self.enqueue(id, node.level);
    }
    self.bump();
}

/// A failed read or preparation leaves the previous measurement intact.
pub fn retryScan(self: *Service, id: Id) void {
    const node = &self.nodes.items[id];
    node.scanning = false;
    self.enqueue(id, node.level);
}
