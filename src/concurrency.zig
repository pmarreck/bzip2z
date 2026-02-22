const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn BoundedQueue(comptime T: type) type {
	return struct {
		const Self = @This();

		items: []T,
		allocator: Allocator,
		mutex: std.Thread.Mutex,
		not_empty: std.Thread.Condition,
		not_full: std.Thread.Condition,
		capacity: usize,
		closed: bool,
		head: usize,
		tail: usize,
		count: usize,

		pub fn init(allocator: Allocator, capacity: usize) !Self {
			const cap = @max(@as(usize, 1), capacity);
			const items = try allocator.alloc(T, cap);
			return .{
				.items = items,
				.allocator = allocator,
				.mutex = .{},
				.not_empty = .{},
				.not_full = .{},
				.capacity = cap,
				.closed = false,
				.head = 0,
				.tail = 0,
				.count = 0,
			};
		}

		pub fn deinit(self: *Self) void {
			self.allocator.free(self.items);
		}

		pub fn enqueue(self: *Self, item: T) bool {
			self.mutex.lock();
			defer self.mutex.unlock();

			while (self.count >= self.capacity and !self.closed) {
				self.not_full.wait(&self.mutex);
			}

			if (self.closed) {
				return false;
			}

			self.items[self.tail] = item;
			self.tail = (self.tail + 1) % self.capacity;
			self.count += 1;

			self.not_empty.signal();
			return true;
		}

		pub fn dequeue(self: *Self) ?T {
			self.mutex.lock();
			defer self.mutex.unlock();

			while (self.count == 0 and !self.closed) {
				self.not_empty.wait(&self.mutex);
			}

			if (self.count == 0) {
				return null;
			}

			const item = self.items[self.head];
			self.head = (self.head + 1) % self.capacity;
			self.count -= 1;

			self.not_full.signal();
			return item;
		}

		pub fn tryDequeue(self: *Self) ?T {
			self.mutex.lock();
			defer self.mutex.unlock();

			if (self.count == 0) {
				return null;
			}

			const item = self.items[self.head];
			self.head = (self.head + 1) % self.capacity;
			self.count -= 1;

			self.not_full.signal();
			return item;
		}

		pub fn close(self: *Self) void {
			self.mutex.lock();
			defer self.mutex.unlock();

			self.closed = true;
			self.not_empty.broadcast();
			self.not_full.broadcast();
		}

		pub fn isClosed(self: *Self) bool {
			self.mutex.lock();
			defer self.mutex.unlock();
			return self.closed;
		}

		pub fn len(self: *Self) usize {
			self.mutex.lock();
			defer self.mutex.unlock();
			return self.count;
		}
	};
}
