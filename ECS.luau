local RunService = game:GetService("RunService")
local band = bit32.band

export type Entity = number

export type Comp<T> = {
	_b: number,
	_d: { [number]: T },
}

export type Query = {
	_w: World,
	_m: number,
	iter: (self: Query) -> () -> (Entity, number)?,
}

export type System = (world: World, dt: number) -> ()

export type World = {
	_e: { Entity },
	_s: { number },
	_n: number,

	_i: { [Entity]: number },
	_nx: number,
	_f: { Entity },

	_c: { Comp<any> },
	_b: number,

	_sys: { System },
	_con: RBXScriptConnection?,

	register: <T>(self: World) -> Comp<T>,
	spawn: (self: World) -> Entity,
	set: <T>(self: World, e: Entity, c: Comp<T>, v: T) -> (),
	get: <T>(self: World, e: Entity, c: Comp<T>) -> T?,
	remove: <T>(self: World, e: Entity, c: Comp<T>) -> (),
	kill: (self: World, e: Entity) -> (),
	query: (self: World, ...Comp<any>) -> Query,
	system: (self: World, fn: System) -> (),
	start: (self: World) -> (),
	stop: (self: World) -> (),
}

local function queryIter(q: Query): () -> (Entity, number)?
	local w = q._w
	local sig = w._s
	local mask = q._m
	local i = 0
	local n = w._n
	return function(): (Entity, number)?
		while true do
			i += 1
			if i > n then return nil end
			if band(sig[i], mask) == mask then
				return w._e[i], i
			end
		end
	end
end

local function world(): World
	local self = {} :: any

	self._e = {}
	self._s = {}
	self._n = 0

	self._i = {}
	self._nx = 1
	self._f = {}

	self._c = {}
	self._b = 0

	self._sys = {}
	self._con = nil

	function self.register<T>(_: World): Comp<T>
		self._b += 1
		local bit = 2 ^ (self._b - 1)
		local c = { _b = bit, _d = {} } :: Comp<T>
		table.insert(self._c, c)
		return c
	end

	function self.spawn(_: World): Entity
		local n = self._n + 1
		self._n = n

		local id: Entity
		if #self._f > 0 then
			id = self._f[#self._f] :: Entity
			self._f[#self._f] = nil
		else
			id = self._nx
			self._nx += 1
		end

		self._e[n] = id
		self._s[n] = 0
		self._i[id] = n
		return id
	end

	function self.set<T>(_: World, e: Entity, c: Comp<T>, v: T)
		local idx = self._i[e]
		if not idx then return end
		c._d[idx] = v
		local sig = self._s[idx]
		if band(sig, c._b) == 0 then
			self._s[idx] = sig + c._b
		end
	end

	function self.get<T>(_: World, e: Entity, c: Comp<T>): T?
		local idx = self._i[e]
		if not idx then return nil end
		return c._d[idx]
	end

	function self.remove<T>(_: World, e: Entity, c: Comp<T>)
		local idx = self._i[e]
		if not idx then return end
		local sig = self._s[idx]
		if band(sig, c._b) == c._b then
			self._s[idx] = sig - c._b
			c._d[idx] = nil
		end
	end

	function self.kill(_: World, e: Entity)
		local idx = self._i[e]
		if not idx then return end
		local last = self._n

		if idx ~= last then
			local lastId = self._e[last]
			self._e[idx] = lastId
			self._s[idx] = self._s[last]
			self._i[lastId] = idx

			for _, c in self._c do
				c._d[idx] = c._d[last]
				c._d[last] = nil
			end
		else
			for _, c in self._c do
				c._d[last] = nil
			end
		end

		self._n = last - 1
		self._e[last] = nil
		self._s[last] = nil
		self._i[e] = nil
		table.insert(self._f, e)
	end

	function self.query(_: World, ...: Comp<any>): Query
		local m = 0
		for i = 1, select("#", ...) do
			local c = select(i, ...) :: Comp<any>
			m += c._b
		end
		return { _w = self, _m = m, iter = queryIter } :: Query
	end

	function self.system(_: World, fn: System)
		table.insert(self._sys, fn)
	end

	function self.start(_: World)
		if self._con then return end
		self._con = RunService.Heartbeat:Connect(function(dt: number)
			for _, fn in self._sys do
				fn(self :: World, dt)
			end
		end)
	end

	function self.stop(_: World)
		local con = self._con
		if con then
			con:Disconnect()
			self._con = nil
		end
	end

	return self :: World
end

local function demo()
	local w = world()

	local Position = w:register() :: Comp<Vector3>
	local Velocity = w:register() :: Comp<Vector3>

	for _ = 1, 5000 do
		local e = w:spawn()
		w:set(e, Position, Vector3.new(math.random() * 100, 0, math.random() * 100))
		w:set(e, Velocity, Vector3.new(math.random() - 0.5, 0, math.random() - 0.5))
	end

	local mask = Position._b + Velocity._b

	w:system(function(self, dt: number)
		local sig = self._s
		local n = self._n
		local px = Position._d
		local vx = Velocity._d

		for i = 1, n do
			if band(sig[i], mask) == mask then
				px[i] += vx[i] * dt
			end
		end
	end)

	w:start()
	return w
end

return {
	world = world,
	demo = demo,
}
