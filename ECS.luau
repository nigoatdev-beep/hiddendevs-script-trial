local RunService = game:GetService("RunService") -- Get Roblox RunService to hook into Heartbeat for update loops
local band = bit32.band -- Local reference to bit32.band for fast bitwise AND operations

export type Entity = number -- Define a type alias: an Entity is represented by a numeric id

export type Comp<T> = { -- Define a generic component table type
	_b: number, -- _b will store the component's bitmask value
	_d: { [number]: T }, -- _d maps internal entity indices to component data of type T
}

export type Query = { -- Define a Query type used to iterate entities matching a mask
	_w: World, -- Reference to the World the query belongs to
	_m: number, -- Mask representing required components
	iter: (self: Query) -> () -> (Entity, number)?, -- Iterator factory: returns an iterator that yields (Entity, index)
}

export type System = (world: World, dt: number) -> () -- System is a function that runs each frame with world and delta time

export type World = { -- Define the World type with its internal structures and methods
	_e: { Entity }, -- Array mapping internal index -> Entity id
	_s: { number }, -- Array of signature masks for each internal index (which components an entity has)
	_n: number, -- Current count of active entities (length of the packed arrays)

	_i: { [Entity]: number }, -- Map from Entity id -> internal index in the packed arrays
	_nx: number, -- Next unused entity id to allocate if no recycled ids are available
	_f: { Entity }, -- Stack/array of freed entity ids available for reuse

	_c: { Comp<any> }, -- Array of registered components (each has a bit and data table)
	_b: number, -- Number of registered components (used to assign bits)

	_sys: { System }, -- Array of systems to run each frame
	_con: RBXScriptConnection?, -- Connection to RunService.Heartbeat for ticking systems

	register: <T>(self: World) -> Comp<T>, -- Method signatures: register component
	spawn: (self: World) -> Entity, -- Spawn a new entity
	set: <T>(self: World, e: Entity, c: Comp<T>, v: T) -> (), -- Add/set component data for an entity
	get: <T>(self: World, e: Entity, c: Comp<T>) -> T?, -- Get component data for an entity
	remove: <T>(self: World, e: Entity, c: Comp<T>) -> (), -- Remove a component from an entity
	kill: (self: World, e: Entity) -> (), -- Destroy an entity and recycle index/id
	query: (self: World, ...Comp<any>) -> Query, -- Create a query for a set of components
	system: (self: World, fn: System) -> (), -- Register a system
	start: (self: World) -> (), -- Start running systems on Heartbeat
	stop: (self: World) -> (), -- Stop running systems
}

local function queryIter(q: Query): () -> (Entity, number)? -- Define iterator factory that yields entities matching a query mask
	local w = q._w -- local alias to the world in the query
	local sig = w._s -- local alias to the world's signature array
	local mask = q._m -- local alias to the query's required component mask
	local i = 0 -- iterator counter over packed indices
	local n = w._n -- number of active entities to iterate up to
	return function(): (Entity, number)? -- return the iterator function
		while true do -- loop until we return a match or nil
			i += 1 -- advance to next index
			if i > n then return nil end -- if past end, finish iteration
			if band(sig[i], mask) == mask then -- check if entity at index has all bits in mask
				return w._e[i], i -- yield the Entity id and its internal index
			end
		end
	end
end

local function world(): World -- Factory creating a new World instance
	local self = {} :: any -- Use a local table to hold world state and methods (annotated as any)

	self._e = {} -- packed array mapping index -> entity id
	self._s = {} -- packed array mapping index -> signature mask
	self._n = 0 -- number of active packed entries

	self._i = {} -- map entity id -> packed index
	self._nx = 1 -- next new entity id (incrementing)
	self._f = {} -- free list of recycled entity ids

	self._c = {} -- array of registered component descriptors
	self._b = 0 -- component registration count (used to assign bit positions)

	self._sys = {} -- array of systems to run each tick
	self._con = nil -- connection to Heartbeat (initially none)

	function self.register<T>(_: World): Comp<T> -- Method to register a new component type
		self._b += 1 -- increment the component registration counter
		local bit = 2 ^ (self._b - 1) -- compute the bit value for this component (1 << (b-1))
		local c = { _b = bit, _d = {} } :: Comp<T> -- create component descriptor with bit and empty data table
		table.insert(self._c, c) -- append descriptor to component list
		return c -- return the component descriptor for use
	end

	function self.spawn(_: World): Entity -- Method to spawn/allocate a new entity
		local n = self._n + 1 -- compute new packed length (we will add an entry)
		self._n = n -- update stored packed length

		local id: Entity -- declare variable for entity id to assign
		if #self._f > 0 then -- if there are recycled entity ids available
			id = self._f[#self._f] :: Entity -- pop last free id
			self._f[#self._f] = nil -- remove it from free list
		else
			id = self._nx -- otherwise use next incremental id
			self._nx += 1 -- increment next id counter
		end

		self._e[n] = id -- store entity id at the new packed index
		self._s[n] = 0 -- initialize its signature mask to 0 (no components)
		self._i[id] = n -- map the entity id to its packed index
		return id -- return the new Entity id
	end

	function self.set<T>(_: World, e: Entity, c: Comp<T>, v: T) -- Method to set/add component data for an entity
		local idx = self._i[e] -- find the packed index for the entity id
		if not idx then return end -- if entity not found, do nothing
		c._d[idx] = v -- store the component data at the entity's packed index
		local sig = self._s[idx] -- read current signature at that index
		if band(sig, c._b) == 0 then -- if the component bit is not already set in signature
			self._s[idx] = sig + c._b -- add the component's bit to the signature (set it)
		end
	end

	function self.get<T>(_: World, e: Entity, c: Comp<T>): T? -- Get component data for an entity if present
		local idx = self._i[e] -- look up packed index for entity id
		if not idx then return nil end -- if entity missing, return nil
		return c._d[idx] -- return component data (may be nil if not present)
	end

	function self.remove<T>(_: World, e: Entity, c: Comp<T>) -- Remove a component from an entity
		local idx = self._i[e] -- lookup packed index
		if not idx then return end -- if entity not found, do nothing
		local sig = self._s[idx] -- get current signature
		if band(sig, c._b) == c._b then -- if the component bit is set in the signature
			self._s[idx] = sig - c._b -- remove the bit from the signature
			c._d[idx] = nil -- remove the component data entry
		end
	end

	function self.kill(_: World, e: Entity) -- Destroy an entity and compact/recycle storage
		local idx = self._i[e] -- get packed index for entity
		if not idx then return end -- if entity not found, nothing to do
		local last = self._n -- last packed index currently used

		if idx ~= last then -- if removing an entity that isn't the last slot, swap last into idx
			local lastId = self._e[last] -- entity id at the last slot
			self._e[idx] = lastId -- move last entity id into the removed slot
			self._s[idx] = self._s[last] -- move last signature into the removed slot
			self._i[lastId] = idx -- update mapping for moved entity

			for _, c in self._c do -- for each registered component
				c._d[idx] = c._d[last] -- move component data from last slot into idx
				c._d[last] = nil -- clear the last slot for that component
			end
		else
			for _, c in self._c do -- if removing the last slot, just clear component data from last
				c._d[last] = nil -- clear each component's data at last index
			end
		end

		self._n = last - 1 -- decrement the packed entity count
		self._e[last] = nil -- clear the last entity id slot
		self._s[last] = nil -- clear the last signature slot
		self._i[e] = nil -- remove mapping for the killed entity id
		table.insert(self._f, e) -- push the killed entity id onto the free/recycle list
	end

	function self.query(_: World, ...: Comp<any>): Query -- Build a query for the given components
		local m = 0 -- mask accumulator
		for i = 1, select("#", ...) do -- iterate over variadic arguments
			local c = select(i, ...) :: Comp<any> -- select the i-th component argument
			m += c._b -- add its bit to the mask (sum of powers of two equals bitwise OR when unique)
		end
		return { _w = self, _m = m, iter = queryIter } :: Query -- return Query with world, mask and iterator factory
	end

	function self.system(_: World, fn: System) -- Register a system function to be run each tick
		table.insert(self._sys, fn) -- append the system to the list
	end

	function self.start(_: World) -- Start running systems on Heartbeat
		if self._con then return end -- if already started, do nothing
		self._con = RunService.Heartbeat:Connect(function(dt: number) -- connect to Heartbeat and store the connection
			for _, fn in self._sys do -- iterate registered systems
				fn(self :: World, dt) -- call each system with world and delta time
			end
		end)
	end

	function self.stop(_: World) -- Stop running systems by disconnecting the Heartbeat connection
		local con = self._con -- read stored connection
		if con then -- if there is a connection
			con:Disconnect() -- disconnect it
			self._con = nil -- clear the stored connection
		end
	end

	return self :: World -- return the constructed World instance
end

local function demo() -- Example/demo function that creates a world and populates entities
	local w = world() -- create a new World instance

	local Position = w:register() :: Comp<Vector3> -- register a Position component and annotate its type
	local Velocity = w:register() :: Comp<Vector3> -- register a Velocity component and annotate its type

	for _ = 1, 5000 do -- create 5000 entities for benchmarking/demo
		local e = w:spawn() -- spawn a new entity id
		w:set(e, Position, Vector3.new(math.random() * 100, 0, math.random() * 100)) -- set random Position for the entity
		w:set(e, Velocity, Vector3.new(math.random() - 0.5, 0, math.random() - 0.5)) -- set random Velocity for the entity
	end

	local mask = Position._b + Velocity._b -- compute combined mask for entities having both Position and Velocity

	w:system(function(self, dt: number) -- register a system that integrates position by velocity
		local sig = self._s -- local alias to signatures array
		local n = self._n -- local alias to number of active entities
		local px = Position._d -- local alias to position data table (indexed by packed index)
		local vx = Velocity._d -- local alias to velocity data table

		for i = 1, n do -- iterate over all packed indices
			if band(sig[i], mask) == mask then -- if entity at index has both Position and Velocity bits
				px[i] += vx[i] * dt -- integrate position by velocity scaled by delta time
			end
		end
	end)

	w:start() -- start the world's systems running on Heartbeat
	return w -- return the world instance so caller can inspect or stop it
end

return {
	world = world, -- export the world factory
	demo = demo, -- export the demo helper
}
