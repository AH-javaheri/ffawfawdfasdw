-- =============================================================================
-- DRESSING ROOM SERVER MODULE
-- Server-authoritative room reservation, queue management, and state tracking.
-- Per-Shop Architecture.
-- =============================================================================

local DR = {}

-- Store-specific state
-- shopState[shopIndex] = { rooms = {...}, queue = {...} }
local shopState = {}

-- playerState[source]
local playerState = {}

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function logDebug(msg)
    if Config.Debug then
        print("^5[DressingRoom]^0 " .. tostring(msg))
    end
end

local function getOrCreateShopState(shopIndex)
    if not shopState[shopIndex] then
        local store = Config.Stores[shopIndex]
        local rooms = {}
        if store and store.dressingRooms then
            for i, def in ipairs(store.dressingRooms) do
                rooms[i] = {
                    id = i, coords = def.coords, bucket = def.bucket,
                    occupied = false, occupant = nil
                }
            end
        end
        shopState[shopIndex] = { rooms = rooms, queue = {} }
        logDebug("Loaded " .. #rooms .. " dressing room(s) for shop " .. shopIndex)
    end
    return shopState[shopIndex]
end

local function getAvailableRoom(shopIndex)
    local state = getOrCreateShopState(shopIndex)
    for _, room in pairs(state.rooms) do
        if not room.occupied then
            return room
        end
    end
    return nil
end

local function isInQueue(src, shopIndex)
    for _, s in ipairs(getOrCreateShopState(shopIndex).queue) do
        if s == src then return true end
    end
    return false
end

local function removeFromQueue(src, shopIndex)
    local state = getOrCreateShopState(shopIndex)
    for i, s in ipairs(state.queue) do
        if s == src then
            table.remove(state.queue, i)
            return
        end
    end
end

local function getQueuePosition(src, shopIndex)
    for i, s in ipairs(getOrCreateShopState(shopIndex).queue) do
        if s == src then return i end
    end
    return nil
end

-- ── Room Reservation ─────────────────────────────────────────────────────────

local function reserveRoom(src, room, shopType, originalCoords, prevBucket, shopIndex)
    room.occupied = true
    room.occupant = src

    playerState[src] = {
        shopIndex      = shopIndex,
        roomId         = room.id,
        originalCoords = originalCoords,
        shopType       = shopType,
        prevBucket     = prevBucket,
        inQueue        = false
    }

    local settings = Config.Stores[shopIndex] and Config.Stores[shopIndex].teleportSettings or {}
    if settings.useRoutingBuckets ~= false then
        SetPlayerRoutingBucket(src, room.bucket)
    end

    logDebug("Reserved room " .. room.id .. " for player " .. src .. " in shop " .. shopIndex)

    TriggerClientEvent("apex-clothing:dressingroom:enter", src, {
        roomId  = room.id,
        coords  = room.coords,
        bucket  = room.bucket,
    })
end

local function freeRoom(src)
    local state = playerState[src]
    if not state or not state.roomId then return end

    local shopIndex = state.shopIndex
    local shop = getOrCreateShopState(shopIndex)
    local room = shop.rooms[state.roomId]

    if room then
        room.occupied = false
        room.occupant = nil
        logDebug("Freed room " .. room.id .. " (was held by player " .. src .. ")")
    end

    playerState[src] = nil

    local settings = Config.Stores[shopIndex] and Config.Stores[shopIndex].teleportSettings or {}
    if settings.useRoutingBuckets ~= false then
        SetPlayerRoutingBucket(src, state.prevBucket or 0)
    end

    if #shop.queue > 0 then
        local nextSrc = table.remove(shop.queue, 1)
        local nextState = playerState[nextSrc]

        if not nextState or not GetPlayerName(nextSrc) then
            freeRoom(src)
            return
        end

        local availRoom = getAvailableRoom(shopIndex)
        if availRoom then
            nextState.inQueue = false
            reserveRoom(nextSrc, availRoom, nextState.shopType, nextState.originalCoords, nextState.prevBucket, shopIndex)

            if settings.notifyIfBusy ~= false then
                lib.notify(nextSrc, {
                    title       = _L("dressingroom.ready.title"),
                    description = _L("dressingroom.ready.description"),
                    type        = "success",
                    position    = Config.NotifyOptions.position
                })
            end
        else
            table.insert(shop.queue, 1, nextSrc)
        end
    end
end

-- ── Public Callbacks ─────────────────────────────────────────────────────────

lib.callback.register("apex-clothing:dressingroom:request", function(source, shopType, originalCoords, prevBucket, shopIndex)
    local src = source

    if not shopIndex or not Config.Stores[shopIndex] then
        return false, "invalid_shop"
    end

    if playerState[src] and playerState[src].roomId then
        logDebug("Player " .. src .. " already has a room – ignoring duplicate request.")
        return false, "already_reserved"
    end

    if isInQueue(src, shopIndex) then
        logDebug("Player " .. src .. " is already in queue – ignoring duplicate request.")
        return false, "already_queued"
    end

    local room = getAvailableRoom(shopIndex)

    if room then
        reserveRoom(src, room, shopType, originalCoords, prevBucket, shopIndex)
        return true, "reserved"
    else
        local settings = Config.Stores[shopIndex].teleportSettings or {}
        if settings.queueEnabled ~= false then
            playerState[src] = {
                shopIndex      = shopIndex,
                roomId         = nil,
                originalCoords = originalCoords,
                shopType       = shopType,
                prevBucket     = prevBucket or 0,
                inQueue        = true
            }
            local shop = getOrCreateShopState(shopIndex)
            table.insert(shop.queue, src)

            local pos = getQueuePosition(src, shopIndex)
            logDebug("Player " .. src .. " queued at position " .. pos .. " for shop " .. shopIndex)

            if settings.notifyIfBusy ~= false then
                lib.notify(src, {
                    title       = _L("dressingroom.queue.title"),
                    description = string.format(_L("dressingroom.queue.description"), pos),
                    type        = "inform",
                    position    = Config.NotifyOptions.position
                })
            end

            local timeout = settings.queueTimeout or 300
            SetTimeout(timeout * 1000, function()
                local pState = playerState[src]
                if pState and pState.inQueue and pState.shopIndex == shopIndex then
                    removeFromQueue(src, shopIndex)
                    playerState[src] = nil
                    if settings.notifyIfBusy ~= false then
                        lib.notify(src, {
                            title       = _L("dressingroom.queue.left.title"),
                            description = "You have been removed from the queue due to timeout.",
                            type        = "error",
                            position    = Config.NotifyOptions.position
                        })
                    end
                end
            end)

            return false, "queued"
        else
            return false, "all_rooms_busy"
        end
    end
end)

RegisterNetEvent("apex-clothing:dressingroom:confirmPurchase", function(shopType)
    local src = source
    local state = playerState[src]

    if not state or not state.roomId then
        logDebug("Player " .. src .. " tried to confirm purchase without a room – blocked.")
        return
    end

    local shopIndex = state.shopIndex
    local settings = Config.Stores[shopIndex] and Config.Stores[shopIndex].teleportSettings or {}

    local money = 0
    if shopType == "clothing" then
        money = Config.ClothingCost
    elseif shopType == "barber" then
        money = Config.BarberCost
    elseif shopType == "tattoo" then
        money = Config.TattooCost
    elseif shopType == "surgeon" then
        money = Config.SurgeonCost
    end

    if Framework.RemoveMoney(src, "cash", money) then
        lib.notify(src, {
            title       = _L("purchase.store.success.title"),
            description = string.format(_L("purchase.store.success.description"), money, shopType),
            type        = "success",
            position    = Config.NotifyOptions.position
        })
    else
        lib.notify(src, {
            title       = _L("purchase.store.failure.title"),
            description = _L("purchase.store.failure.description"),
            type        = "error",
            position    = Config.NotifyOptions.position
        })
    end

    if settings.restoreCoords ~= false then
        TriggerClientEvent("apex-clothing:dressingroom:returnToShop", src, state.originalCoords)
    else
        TriggerClientEvent("apex-clothing:dressingroom:returnToShop", src, nil)
    end

    freeRoom(src)
end)

RegisterNetEvent("apex-clothing:dressingroom:cancel", function()
    local src = source
    local state = playerState[src]

    if not state or not state.roomId then
        logDebug("Player " .. src .. " sent cancel without a room – ignored.")
        return
    end

    local shopIndex = state.shopIndex
    local settings = Config.Stores[shopIndex] and Config.Stores[shopIndex].teleportSettings or {}

    if settings.restoreCoords ~= false then
        TriggerClientEvent("apex-clothing:dressingroom:returnToShop", src, state.originalCoords)
    else
        TriggerClientEvent("apex-clothing:dressingroom:returnToShop", src, nil)
    end

    freeRoom(src)
end)

RegisterNetEvent("apex-clothing:dressingroom:leaveQueue", function()
    local src = source
    local state = playerState[src]

    if not state or not state.inQueue then
        return
    end

    removeFromQueue(src, state.shopIndex)
    playerState[src] = nil

    logDebug("Player " .. src .. " left the queue voluntarily.")

    lib.notify(src, {
        title       = _L("dressingroom.queue.left.title"),
        description = _L("dressingroom.queue.left.description"),
        type        = "inform",
        position    = Config.NotifyOptions.position
    })
end)

AddEventHandler("playerDropped", function()
    local src = source
    local state = playerState[src]

    if not state then return end

    if state.inQueue then
        removeFromQueue(src, state.shopIndex)
        playerState[src] = nil
        logDebug("Queued player " .. src .. " dropped – removed from queue.")
        return
    end

    if state.roomId then
        logDebug("Player " .. src .. " dropped while in room " .. state.roomId .. " – releasing.")
        freeRoom(src)
    end
end)
