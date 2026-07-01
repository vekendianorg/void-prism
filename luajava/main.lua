--- START OF FILE void-prism/luajava/main.lua ---

-- Prism
local Prism = {}

-- External Lua imports
Prism.Json = require("json")

-- Java imports
Prism.Crypto = luajava.bindClass("org.vekendian.Crypto")
local File = luajava.bindClass("java.io.File")

-- Paths
Prism.Paths = {}
Prism.Paths.CONTENT = "/data/user/0/com.waxmoon.ma.gp/rootfs/data/user/0/com.fingersoft.hcr2/files/content_cache/"
Prism.Paths.PACKAGES = Prism.Paths.CONTENT .. "packages/"
Prism.Paths.INDEX = Prism.Paths.PACKAGES .. ".packages"
Prism.Paths.JSON = Prism.Paths.CONTENT .. "json/"
Prism.Paths.EVENTS = Prism.Paths.JSON .. "events/"
Prism.Paths.SEASONS = Prism.Paths.JSON .. "seasons/"
Prism.Paths.SHOP = Prism.Paths.JSON .. "shop/"

-- Logging
Prism.Paths.LOG = gg.getFile():gsub("[^/]+$", "prism.log")

local function log(msg)
    local f = io.open(Prism.Paths.LOG, "a")
    if f then
        f:write("[" .. os.date("%H:%M:%S") .. "] " .. tostring(msg) .. "\n")
        f:close()
    end
end
Prism.Log = log

-- Modules
Prism.Loader = require("loader")
Prism.Builder = require("builder")
Prism.Validator = require("validator")

-- Initialize modules
Prism.Loader.init(Prism)
Prism.Builder.init(Prism)
Prism.Validator.init(Prism)

-- ======================================================================
-- USER INTERFACE
-- ======================================================================

local function uiInstallPack()
    local defaultPath = "/storage/sdcard0/#Vekendian/void-prism/examples/CoolModPack"
    
    local prompt = gg.prompt(
        {"Enter Mod Pack Directory Path:"}, 
        {defaultPath}, 
        {"text"}
    )
    if not prompt then return end
    local packPath = prompt[1]

    -- 1. Read Manifest to get packId
    local manifestPath = packPath .. "/manifest.json"
    local f = io.open(manifestPath, "rb")
    if not f then
        gg.alert("Failed to find manifest.json in:\n" .. packPath)
        return
    end
    local content = f:read("*a")
    f:close()

    local ok, manifest = pcall(Prism.Json.decode, content)
    if not ok or type(manifest) ~= "table" or not manifest.id then
        gg.alert("Invalid manifest.json! Missing 'id'.")
        return
    end

    local packId = manifest.id
    local packName = manifest.name or packId

    -- 2. Scan Pack
    gg.toast("Scanning pack assets...")
    log("UI: Scanning vehicle pack at " .. packPath)
    local vehicleFiles, scanErr = Prism.Loader.scanVehiclePack(packPath)
    if not vehicleFiles then
        gg.alert("Scan failed:\n" .. tostring(scanErr))
        return
    end

    if #vehicleFiles == 0 then
        gg.alert("No vehicle files found in packages/ directory!")
        return
    end

    -- 3. Read Index
    gg.toast("Reading .packages...")
    local index, indexErr = Prism.Loader.readIndex()
    if not index then
        gg.alert("Failed to read game index:\n" .. tostring(indexErr))
        return
    end

    -- 4. Install Pack
    gg.toast("Installing " .. packName .. "...")
    log("UI: Installing pack ID: " .. packId)
    local okInstall, report = Prism.Builder.installVehiclePack(index, vehicleFiles, packId)
    
    if okInstall then
        gg.alert("Successfully installed:\n" .. packName .. " (" .. packId .. ")")
        log("UI: Install SUCCESS for " .. packId)
    else
        gg.alert("Install failed:\n" .. tostring(report.err))
        log("UI: Install FAIL for " .. packId .. " - " .. tostring(report.err))
    end
end

--[[
  uiUninstallPack body, wrapped by the pcall in the outer function below.
  Kept as its own local so xpcall's traceback handler (debug.traceback)
  can attribute the error to a real line number inside this function,
  not to the pcall call site.
]]
local function uiUninstallPackInner()
    gg.toast("Reading .packages...")
    log("uiUninstallPack: reading index")
    local index, indexErr = Prism.Loader.readIndex()
    if not index then
        gg.alert("Failed to read game index:\n" .. tostring(indexErr))
        return
    end

    -- Find all currently installed pack IDs
    log("uiUninstallPack: scanning index.list for installed packs, #index.list=" .. tostring(#index.list))
    local installedPacks = {}
    local installedMap = {}

    for i = 1, #index.list do
        local entry = index.list[i]
        if entry.prism and entry.prism.packs then
            log("uiUninstallPack: entry[" .. tostring(i) .. "] (" .. tostring(entry.name) .. ") has " .. tostring(#entry.prism.packs) .. " prism pack(s)")
            for _, p in ipairs(entry.prism.packs) do
                if type(p) ~= "table" then
                    log("uiUninstallPack: WARNING entry[" .. tostring(i) .. "] prism.packs contains a non-table element: " .. tostring(p))
                elseif p.id == nil then
                    log("uiUninstallPack: WARNING entry[" .. tostring(i) .. "] prism.packs has an element with no id field")
                elseif not installedMap[p.id] then
                    installedMap[p.id] = true
                    table.insert(installedPacks, p.id)
                end
            end
        end
    end

    log("uiUninstallPack: found " .. tostring(#installedPacks) .. " installed pack id(s)")

    if #installedPacks == 0 then
        gg.alert("No Prism mod packs are currently installed!")
        return
    end

    log("uiUninstallPack: opening gg.choice")
    local choice = gg.choice(installedPacks, nil, "Select a mod pack to UNINSTALL:")
    log("uiUninstallPack: gg.choice returned " .. tostring(choice))
    if not choice then return end

    local packIdToUninstall = installedPacks[choice]

    gg.toast("Uninstalling " .. packIdToUninstall .. "...")
    log("UI: Uninstalling pack ID: " .. packIdToUninstall)
    local okUn, repUn = Prism.Builder.uninstallPack(index, packIdToUninstall)
    log("uiUninstallPack: Builder.uninstallPack returned ok=" .. tostring(okUn))

    if okUn then
        gg.alert("Successfully uninstalled:\n" .. packIdToUninstall)
        log("UI: Uninstall SUCCESS for " .. packIdToUninstall)
    else
        gg.alert("Uninstall failed:\n" .. tostring(repUn and repUn.err))
        log("UI: Uninstall FAIL for " .. packIdToUninstall .. " - " .. tostring(repUn and repUn.err))
    end
end

--[[
  uiUninstallPack()

  Diagnostic wrapper around uiUninstallPackInner. Uninstall was silently
  killing the whole GG script mid-function with nothing written to
  prism.log after "readIndex: done" - meaning the error was a raw Lua
  runtime error escaping uncaught (GG's script host appears to just abort
  silently on an uncaught error rather than showing anything), not a
  reported/handled failure. xpcall + debug.traceback catches that error
  instead of letting it kill the script, and logs exactly which line
  and what the error was, so this stays fixed for future regressions too.
]]
local function uiUninstallPack()
    local ok, err = xpcall(uiUninstallPackInner, debug.traceback)
    if not ok then
        log("UI: Uninstall CRASHED - " .. tostring(err))
        gg.alert("Uninstall crashed - see prism.log for details:\n" .. tostring(err))
    end
end

local function mainMenu()
    -- Hide GG overlay so prompts/choices show up cleanly
    gg.setVisible(false)

    while true do
        local choice = gg.choice(
            {"[+] Install Mod Pack", "[-] Uninstall Mod Pack", "[x] Exit"}, 
            nil, 
            "Void Prism - Mod Loader\nLog path: " .. Prism.Paths.LOG
        )

        if not choice or choice == 3 then
            gg.toast("Exiting Prism.")
            break
        elseif choice == 1 then
            uiInstallPack()
        elseif choice == 2 then
            uiUninstallPack()
        end
    end
end

-- Start the UI
log("==========================================")
log("             PRISM STARTED                ")
log("==========================================")

mainMenu()

return Prism
--- END OF FILE void-prism/luajava/main.lua ---