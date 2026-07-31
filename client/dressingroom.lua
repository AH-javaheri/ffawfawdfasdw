-- =============================================================================
-- DRESSING ROOM CLIENT MODULE
-- Intercepts the clothing-shop purchase flow, teleports the player into a
-- dressing room, re-opens the customisation menu, and returns them afterwards.
-- =============================================================================

local DR = {}

-- ── Module State ──────────────────────────────────────────────────────────────
DR.active         = false
DR.previousAppearance = nil
DR.shopType       = nil
DR.originalCoords = nil
DR.inQueue        = false
DR.shopIndex      = nil

-- ── Teleport Helper ───────────────────────────────────────────────────────────
local function teleportToCoords(coords)
    local ped = cache.ped
    SetEntityCoords(ped, coords.x, coords.y, coords.z, false, false, false, false)
    SetEntityHeading(ped, coords.w)

    local timeout = 0
    repeat
        Wait(100)
        timeout = timeout + 100
    until (GetEntityCoords(ped) - vector3(coords.x, coords.y, coords.z)):Length() < 2.0 or timeout > 5000
end

-- ── Purchase Interception Entry Point ─────────────────────────────────────────
function DR.requestRoom(shopType, savedAppearance, shopIndex)
    if DR.active then
        return false
    end

    local ped     = cache.ped
    local pos     = GetEntityCoords(ped)
    local heading = GetEntityHeading(ped)
    DR.originalCoords = vector4(pos.x, pos.y, pos.z, heading)
    DR.shopType       = shopType
    DR.shopIndex      = shopIndex
    DR.previousAppearance = savedAppearance

    local prevBucket = GetPlayerRoutingBucket(PlayerId())

    local ok, reason = lib.callback.await(
        "apex-clothing:dressingroom:request",
        false,
        shopType,
        DR.originalCoords,
        prevBucket,
        shopIndex
    )

    if not ok then
        if reason == "queued" then
            DR.inQueue = true
            DR._showQueueMenu()
            return true
        elseif reason == "already_reserved" or reason == "already_queued" then
            return true
        elseif reason == "all_rooms_busy" then
            lib.notify({
                title = "Rooms Busy",
                description = "All dressing rooms are currently busy. Please try again later.",
                type = "error", position = Config.NotifyOptions.position
            })
            return false
        else
            return false
        end
    end

    return true
end

-- ── Queue Cancel UI ───────────────────────────────────────────────────────────
function DR._showQueueMenu()
    CreateThread(function()
        local result = lib.alertDialog({
            header  = _L("dressingroom.queue.waiting.title"),
            content = _L("dressingroom.queue.waiting.content"),
            cancel  = true,
            labels  = {
                cancel  = _L("dressingroom.queue.cancel.label"),
                confirm = ""
            }
        })

        if DR.inQueue then
            TriggerServerEvent("apex-clothing:dressingroom:leaveQueue")
            DR.inQueue = false
        end
    end)
end

-- ── Server → Client: Room Ready ───────────────────────────────────────────────
RegisterNetEvent("apex-clothing:dressingroom:enter", function(roomData)
    DR.inQueue = false
    DR.active  = true

    teleportToCoords(roomData.coords)

    DR._openMenuInRoom()
end)

function DR._openMenuInRoom()
    local config = GetDefaultConfig()
    config.components = true
    config.props      = true

    client.startPlayerCustomization(function(appearance)
        if appearance then
            TriggerServerEvent("apex-clothing:dressingroom:confirmPurchase", DR.shopType)
            TriggerServerEvent("illenium-appearance:server:saveAppearance", appearance)
        else
            if DR.previousAppearance then
                client.setPlayerAppearance(DR.previousAppearance)
            end
            TriggerServerEvent("apex-clothing:dressingroom:cancel")
        end
        Framework.CachePed()
    end, config)
end

-- ── Server → Client: Return to Shop ─────────────────────────────────────────
RegisterNetEvent("apex-clothing:dressingroom:returnToShop", function(coords)
    DR.active             = false
    DR.previousAppearance = nil
    DR.shopType           = nil
    DR.shopIndex          = nil

    if coords then
        teleportToCoords(coords)
    end
end)

-- ── Exports ───────────────────────────────────────────────────────────────────
exports("DR_requestRoom", DR.requestRoom)
exports("DR_isActive",    function() return DR.active end)

_G.DressingRoom = DR
