--!strict

local Dependencies = require(script.Parent.Parent.Parent.Dependencies)
local Signal = Dependencies.GetSignal()

type Connection = {
	Disconnect: (self: Connection) -> (),
	Connected: boolean,
}

export type ClientRemoteProperty<T> = {
	Get: (self: ClientRemoteProperty<T>) -> T,
	IsReady: (self: ClientRemoteProperty<T>) -> boolean,
	OnReady: (self: ClientRemoteProperty<T>, timeout: number?) -> T?,
	Observe: (self: ClientRemoteProperty<T>, callback: (value: T) -> ()) -> Connection,
	Destroy: (self: ClientRemoteProperty<T>) -> (),
}

type ClientRemotePropertyInternal<T> = {
	_remote: RemoteEvent,
	_getRemote: RemoteFunction,
	_value: T?,
	_ready: boolean,
	_signal: any,
	_connection: RBXScriptConnection?,
}

local ClientRemoteProperty = {}
ClientRemoteProperty.__index = ClientRemoteProperty

function ClientRemoteProperty.new<T>(remoteEvent: RemoteEvent, getRemote: RemoteFunction): ClientRemoteProperty<T>
	local self = setmetatable({
		_remote = remoteEvent,
		_getRemote = getRemote,
		_value = nil :: T?,
		_ready = false,
		_signal = Signal.new(),
		_connection = nil :: RBXScriptConnection?,
	}, ClientRemoteProperty)

	local selfAny = self :: any

	selfAny._connection = remoteEvent.OnClientEvent:Connect(function(value: T)
		selfAny._value = value
		selfAny._ready = true
		selfAny._signal:Fire(value)
	end)

	task.spawn(function()
		local value = getRemote:InvokeServer()
		if not selfAny._ready then
			selfAny._value = value
			selfAny._ready = true
			selfAny._signal:Fire(value)
		end
	end)

	return self :: any
end

function ClientRemoteProperty.Get<T>(self: ClientRemotePropertyInternal<T>): T
	return self._value :: T
end

function ClientRemoteProperty.IsReady<T>(self: ClientRemotePropertyInternal<T>): boolean
	return self._ready
end

function ClientRemoteProperty.OnReady<T>(self: ClientRemotePropertyInternal<T>, timeout: number?): T?
	if self._ready then
		return self._value :: T
	end

	local thread = coroutine.running()
	local connection: Connection
	local timedOut = false

	connection = self._signal:Connect(function(value)
		if timedOut then
			return
		end
		connection:Disconnect()
		task.spawn(thread, value)
	end)

	-- Set up timeout if specified
	if timeout then
		task.delay(timeout, function()
			if not self._ready then
				timedOut = true
				connection:Disconnect()
				task.spawn(thread, nil)
			end
		end)
	end

	return coroutine.yield()
end

function ClientRemoteProperty.Observe<T>(self: ClientRemotePropertyInternal<T>, callback: (value: T) -> ()): Connection
	if self._ready then
		callback(self._value :: T)
	end
	return self._signal:Connect(callback)
end

function ClientRemoteProperty.Destroy<T>(self: ClientRemotePropertyInternal<T>)
	if self._connection then
		self._connection:Disconnect()
	end
	self._signal:Destroy()
end

return ClientRemoteProperty
