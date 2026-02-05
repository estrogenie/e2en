---
sidebar_position: 1
---

# Introduction

e2en is a framework for building Roblox games with a clean separation between server and client code. It provides structure, automatic networking, and lifecycle management so you can focus on building your game instead of boilerplate.

## Why e2en?

### Organized Code Structure

Games grow messy fast. e2en gives you a clear pattern: **Services** run on the server, **Controllers** run on the client, and **Systems** group related code together. Everything has a place.

```
Systems/
├── Combat/
│   ├── Service.luau    -- Server logic
│   ├── Controller.luau -- Client logic
│   └── Shared/         -- Shared code
├── Inventory/
│   ├── Service.luau
│   └── Controller.luau
```

### No More RemoteEvent Spaghetti

Forget creating RemoteEvents manually. Define what you want to expose in your Service and clients can access it automatically.

```lua
-- Server
local CombatService = e2en.CreateService({
    Name = "CombatService",
    Client = {
        DamageDealt = e2en.CreateSignal(),  -- Clients can listen
        PlayerHealth = e2en.CreateProperty(100),  -- Synced state
    },
})

-- Later on the server...
self.Client.DamageDealt:Fire(player, { amount = 25 })
self.Client.PlayerHealth:SetFor(player, 75)
```

```lua
-- Client (automatically available)
local CombatService = e2en.GetService("CombatService")

CombatService.DamageDealt:Connect(function(data)
    print("Took", data.amount, "damage")
end)

CombatService.PlayerHealth:Observe(function(health)
    updateHealthBar(health)
end)
```

### Type Safety Built In

e2en is written in strict Luau from the ground up. You get intellisense, autocomplete, and compile-time error checking.

```lua
local e2en: Types.e2enServer = require(root) :: any

-- Full autocomplete for e2en.CreateService, e2en.GetService, etc.
```

### Automatic Cleanup

Player left? Character died? The framework handles cleanup automatically through integrated Troves. No more lingering connections or memory leaks.

```lua
e2en.OnCharacterAdded(function(player, character, trove)
    -- This connection is automatically disconnected when character dies
    trove:Connect(character.Humanoid.Running, function(speed)
        print(player.Name, "running at", speed)
    end)
end)
```

## Core Concepts

| Concept | Description |
|---------|-------------|
| **Service** | Server-side singleton that handles game logic. Can expose signals, properties, and methods to clients. |
| **Controller** | Client-side singleton that handles local logic and UI. Can communicate with Services. |
| **System** | A folder containing a Service and/or Controller that work together. Keeps related code organized. |
| **RemoteSignal** | Server-to-client event system. Fire to one player, all players, or filtered subsets. |
| **RemoteProperty** | Replicated state with per-player overrides. Clients observe changes reactively. |

## Next Steps

Ready to dive in? Head to [Getting Started](./getting-started) to set up your first e2en project.

Or jump straight to specific topics:
- [Services](./services) - Server-side architecture
- [Controllers](./controllers) - Client-side architecture
- [Communication](./communication) - Networking between server and client
- [Lifecycle](./lifecycle) - Player and character event handling
