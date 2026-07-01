local Builder = {}

local Prism
local Json
local Crypto
local Paths
local Log

-- Forward-declared locals: these are DEFINED further down in this file
-- (deleteDirRecursive alongside restorePackageFromBackup, near the
-- backup/rollback helpers) but are called by functions defined earlier
-- (writePackManifest, uninstallPack, reorderPacks). Lua's `local
-- function` only becomes visible to code written AFTER it, so without
-- this forward declaration those earlier call sites would silently
-- resolve to a nil global instead of the real local and crash at
-- runtime the first time an uninstall/reorder actually runs.
local deleteDirRecursive
local restorePackageFromBackup

-- Java bindings
local File
local FileInputStream
local FileOutputStream
local MessageDigest
local Array
local Byte
local BigInteger

function Builder.init(core)
    Prism = core
    Json = core.Json
    Crypto = core.Crypto
    Paths = core.Paths
    Log = core.Log

    File = luajava.bindClass("java.io.File")
    FileInputStream = luajava.bindClass("java.io.FileInputStream")
    FileOutputStream = luajava.bindClass("java.io.FileOutputStream")
    MessageDigest = luajava.bindClass("java.security.MessageDigest")
    Array = luajava.bindClass("java.lang.reflect.Array")
    Byte = luajava.bindClass("java.lang.Byte")
    BigInteger = luajava.bindClass("java.math.BigInteger")
end

--[[
  IMPORTANT: Crypto.encrypt requires the same meta table that
  Crypto.decrypt returned for the file being re-encrypted (see
  modules/ops/event.lua):

    local meta = Crypto.decrypt(srcEncrypted, destDecrypted)
    -- ... modify the decrypted plaintext on disk ...
    Crypto.encrypt(destDecrypted, srcEncrypted, meta)

  Loader.readIndex() already stores this as index.cryptoMeta, so any
  Builder function that rebuilds .packages must thread that value through
  to its own Crypto.encrypt call rather than re-deriving it.
]]

local function newByteBuffer(size)
    return Array.newInstance(Byte.TYPE, size)
end

--[[
  Computes the MD5 checksum of a file on disk, hex-encoded, matching the
  format seen in real .packages entries (e.g. "8472e47254d1a3591f4b027cb60ce77a").
]]
local function md5File(path)
    local ok, result = pcall(function()
        local digest = MessageDigest:getInstance("MD5")
        local fis = luajava.newInstance("java.io.FileInputStream", path)
        local buffer = newByteBuffer(8192)

        local bytesRead = fis.read(buffer)
        while bytesRead ~= -1 do
            digest.update(buffer, 0, bytesRead)
            bytesRead = fis.read(buffer)
        end
        fis.close()

        local hashBytes = digest.digest()
        -- BigInteger(1, bytes) keeps it unsigned/positive, then hex-pad to 32 chars
        local bigInt = BigInteger(1, hashBytes)
        local hex = tostring(bigInt:toString(16))
        while #hex < 32 do
            hex = "0" .. hex
        end
        return hex
    end)

    if not ok then
        Log("md5File: failed for " .. tostring(path) .. ": " .. tostring(result))
        return nil, tostring(result)
    end

    return result
end

--[[
  Copies a single file from src to dest, creating parent directories as
  needed. Used to apply pack files into the real content_cache package dir.
]]
local function copyFile(srcPath, destPath)
    local ok, err = pcall(function()
        local destFile = File(destPath)
        local parent = destFile:getParentFile()
        if parent and not parent:exists() then
            parent:mkdirs()
        end

        -- IMPORTANT: matches core/utils/catbox.lua's proven pattern exactly.
        -- Using luajava.newInstance with a plain string path (not File(...))
        -- and dot-call (fos.write) instead of colon-call (fos:write) - on
        -- this luaj fork, colon-call on FileOutputStream:write(byte[],int,int)
        -- fails overload resolution ("no coercible public method"), but the
        -- dot-call form used elsewhere in Void works fine.
        local fis = luajava.newInstance("java.io.FileInputStream", srcPath)
        local fos = luajava.newInstance("java.io.FileOutputStream", destPath)
        local buffer = newByteBuffer(8192)

        local bytesRead = fis.read(buffer)
        while bytesRead ~= -1 do
            fos.write(buffer, 0, bytesRead)
            bytesRead = fis.read(buffer)
        end

        fis.close()
        fos.flush()
        fos.close()
    end)

    if not ok then
        Log("copyFile: failed " .. tostring(srcPath) .. " -> " .. tostring(destPath) .. ": " .. tostring(err))
        return false, tostring(err)
    end

    return true
end

--[[
  Recursively copies a directory tree. Used to snapshot a real package dir
  before mutating it, so a failed/bad apply can be manually restored.
]]
local function copyDirRecursive(srcDir, destDir)
    local src = File(srcDir)
    if not src:exists() then
        return true -- nothing to back up
    end
    if not src:isDirectory() then
        return copyFile(srcDir, destDir)
    end

    local destFile = File(destDir)
    if not destFile:exists() then
        destFile:mkdirs()
    end

    local entries = src:listFiles()
    if not entries then return true end

    for i = 1, #entries do
        local e = entries[i]
        local name = tostring(e:getName())
        local srcPath = tostring(e:getAbsolutePath())
        local destPath = destDir .. "/" .. name
        if e:isDirectory() then
            local ok = copyDirRecursive(srcPath, destPath)
            if not ok then return false end
        else
            local ok = copyFile(srcPath, destPath)
            if not ok then return false end
        end
    end

    return true
end

--[[
  ============================================================================
  PRISM LAYER SYSTEM (multi-pack install/uninstall/reorder)
  ============================================================================

  Problem: the real game reads packages/<pkg>.zip/... directly, so unlike
  Minecraft's resource pack stack (resolved at load time by the game
  itself), Prism must physically write the "winning" file into place. That
  means a plain "backup original, overwrite" model breaks the moment a
  second pack touches the same file - there's no way to know what the
  first pack's edit was anymore, or to cleanly uninstall one of two packs
  stacked on the same texture.

  Solution: every touched package gets a manifest
  (packages/<pkg>.zip/.prism_manifest.json) tracking, per real relative
  path, a LAYER STACK - one entry per pack that has ever touched that
  file, each with its own preserved copy of what that pack contributed:

    _prism_backup/<relpath>          - the true original game file (or
                                        absent if the file didn't exist
                                        before any pack touched it)
    _prism_layers/<packId>/<relpath> - that pack's own contribution,
                                        preserved independently of the
                                        pack's source folder (which may
                                        be deleted/updated later)

  "Resolving" a file = picking the highest-priority layer's preserved
  content (or the original backup / deletion if no layers remain) and
  copying/writing that into the real destination path. This single
  operation is reused for install (add a layer, resolve), uninstall
  (remove a layer, resolve), and reorder (no layer change, just
  re-resolve everything against new priorities) - so "remove the middle
  pack of three and the top pack's edit still shows" falls out for free.

  Manifest shape:
    {
      "files": {
        "<relativePath>": {
          "hadOriginal": bool,
          -- binary/texture files:
          "layers": [ { packId, priority, appliedPath }, ... ],
          -- array-mergeable JSON files (mergeType present instead):
          "mergeType": "array_append",
          "baseArray": <original array, captured once, immutable>,
          "layers": [ { packId, priority, addedEntries }, ... ]
        },
        ...
      }
    }

  Layers are always kept sorted by ascending priority (low = applied
  first = most easily overwritten, matching the "Lowest Priority" end of
  the Minecraft-style stack described in context.txt).
]]

local PRISM_BACKUP_DIR = "_prism_backup"
local PRISM_LAYERS_DIR = "_prism_layers"
local PRISM_MANIFEST_NAME = ".prism_manifest.json"

--[[
  Builder.readPackManifest(gamePackageDir)

  Reads and decodes a package's .prism_manifest.json, if present.
  Returns an empty-but-valid manifest (not nil) when none exists yet, so
  callers can always index into .files without a nil check.
]]
function Builder.readPackManifest(gamePackageDir)
    local path = gamePackageDir .. "/" .. PRISM_MANIFEST_NAME
    local f = io.open(path, "rb")
    if not f then
        return { files = {} }
    end
    local content = f:read("*a")
    f:close()

    local decodeOk, decoded = pcall(Json.decode, content)
    if not decodeOk or type(decoded) ~= "table" then
        Log("readPackManifest: failed to decode " .. path .. ", treating as empty: " .. tostring(decoded))
        return { files = {} }
    end
    decoded.files = decoded.files or {}
    return decoded
end

--[[
  Builder.writePackManifest(gamePackageDir, manifest)

  Writes the manifest back out. If manifest.files is empty, the manifest
  (and the package's _prism_backup / _prism_layers dirs) are removed
  entirely instead, since an empty manifest means Prism no longer
  manages anything in this package.

  NOTE: relies on deleteDirRecursive, which is defined later in this file
  (as a local function) - Lua's forward-reference-via-upvalue works fine
  here because this function isn't CALLED until after the whole file (and
  therefore that local) has loaded.
]]
function Builder.writePackManifest(gamePackageDir, manifest)
    local hasFiles = false
    for _ in pairs(manifest.files) do hasFiles = true break end

    local manifestPath = gamePackageDir .. "/" .. PRISM_MANIFEST_NAME

    if not hasFiles then
        File(manifestPath):delete()
        deleteDirRecursive(gamePackageDir .. "/" .. PRISM_BACKUP_DIR)
        deleteDirRecursive(gamePackageDir .. "/" .. PRISM_LAYERS_DIR)
        Log("writePackManifest: " .. gamePackageDir .. " has no tracked files left, cleared manifest/backup/layers")
        return true
    end

    local encodeOk, encoded = pcall(Json.encode, manifest)
    if not encodeOk then
        return false, "Failed to encode manifest: " .. tostring(encoded)
    end

    local f = io.open(manifestPath, "wb")
    if not f then
        return false, "Cannot write manifest: " .. manifestPath
    end
    f:write(encoded)
    f:close()
    return true
end

--[[
  sortLayers(layers)

  Sorts a file's layer list ascending by priority in place. Ties (e.g.
  two packs installed with the same priority, which shouldn't normally
  happen but is defensive) fall back to insertion order via a stable
  index tiebreaker.
]]
local function sortLayers(layers)
    for i, l in ipairs(layers) do l.__idx = i end
    table.sort(layers, function(a, b)
        if a.priority ~= b.priority then return a.priority < b.priority end
        return a.__idx < b.__idx
    end)
    for _, l in ipairs(layers) do l.__idx = nil end
end

--[[
  Builder.resolveBinaryFile(gamePackageDir, relPath, fileEntry)

  Re-derives the real on-disk content for one binary/texture file from
  its layer stack: copies the highest-priority layer's preserved copy
  into place, or restores the original backup / deletes the file if no
  layers remain.

  This is the single operation shared by install (after adding a layer),
  uninstall (after removing a layer), and reorder (after re-sorting) -
  it never needs to know WHY the layer stack changed, only what it looks
  like now.
]]
function Builder.resolveBinaryFile(gamePackageDir, relPath, fileEntry)
    local destPath = gamePackageDir .. "/" .. relPath

    if #fileEntry.layers == 0 then
        if fileEntry.hadOriginal then
            local backupPath = gamePackageDir .. "/" .. PRISM_BACKUP_DIR .. "/" .. relPath
            local ok, err = copyFile(backupPath, destPath)
            Log("resolveBinaryFile: " .. relPath .. " -> restored original from backup: " .. tostring(ok))
            return ok, err
        else
            File(destPath):delete()
            Log("resolveBinaryFile: " .. relPath .. " -> no layers, no original, deleted")
            return true
        end
    end

    sortLayers(fileEntry.layers)
    local top = fileEntry.layers[#fileEntry.layers]
    local ok, err = copyFile(top.appliedPath, destPath)
    Log("resolveBinaryFile: " .. relPath .. " -> resolved to top layer (" .. tostring(top.packId) .. "): " .. tostring(ok))
    return ok, err
end

--[[
  Builder.resolveJsonArrayFile(gamePackageDir, relPath, fileEntry)

  Re-derives an array-mergeable JSON file from scratch: baseArray (the
  true original, captured once and never mutated) followed by every
  layer's addedEntries, concatenated in ascending priority order. Unlike
  binary files this ALWAYS recomputes from all remaining layers - there's
  no single "winning" layer for an append-only merge; every surviving
  pack's additions should still be present.
]]
function Builder.resolveJsonArrayFile(gamePackageDir, relPath, fileEntry)
    local destPath = gamePackageDir .. "/" .. relPath

    if #fileEntry.layers == 0 then
        if fileEntry.hadOriginal then
            local encoded = Json.encode(fileEntry.baseArray or {})
            local f = io.open(destPath, "wb")
            if not f then return false, "Cannot write: " .. destPath end
            f:write(encoded)
            f:close()
            Log("resolveJsonArrayFile: " .. relPath .. " -> no layers left, restored base array")
            return true
        else
            File(destPath):delete()
            Log("resolveJsonArrayFile: " .. relPath .. " -> no layers, no original, deleted")
            return true
        end
    end

    sortLayers(fileEntry.layers)
    local merged = {}
    for _, entry in ipairs(fileEntry.baseArray or {}) do
        merged[#merged + 1] = entry
    end
    for _, layer in ipairs(fileEntry.layers) do
        for _, added in ipairs(layer.addedEntries or {}) do
            merged[#merged + 1] = added
        end
    end

    local encoded = Json.encode(merged)
    local f = io.open(destPath, "wb")
    if not f then return false, "Cannot write: " .. destPath end
    f:write(encoded)
    f:close()
    Log("resolveJsonArrayFile: " .. relPath .. " -> resolved " .. tostring(#merged) .. " entries from " .. tostring(#fileEntry.layers) .. " layer(s)")
    return true
end

--[[
  Builder.resolveFile(gamePackageDir, relPath, fileEntry)

  Dispatches to the correct resolve strategy based on fileEntry.mergeType.
]]
function Builder.resolveFile(gamePackageDir, relPath, fileEntry)
    if fileEntry.mergeType == "array_append" then
        return Builder.resolveJsonArrayFile(gamePackageDir, relPath, fileEntry)
    end
    return Builder.resolveBinaryFile(gamePackageDir, relPath, fileEntry)
end

--[[
  Builder.applyLayer(gamePackageDir, manifest, relPath, packId, priority, srcAbsolutePath)

  Adds (or replaces, on reinstall/update of the same pack) one pack's
  layer for one file: preserves that pack's contribution independently
  under _prism_layers/<packId>/<relPath>, captures the true original
  into _prism_backup/ on first-ever touch, then resolves the file.

  Handles both binary files and array-shaped JSON transparently: JSON
  files are probed by attempting an array decode of the pack's own
  content; if that succeeds, the file is tracked as mergeType =
  "array_append" and the pack's array entries become this layer's
  addedEntries (NOT copied whole - only the pack's own entries, so an
  uninstall can precisely remove just what this pack contributed). If
  decode as an array fails (object-shaped JSON, e.g. *_config.json,
  transform.json, particleVariants.json, vehicle_*_model*.json) or the
  file isn't JSON at all, it's treated as an opaque binary layer - this
  covers every other extension seen in the real dump (.png, .plist,
  .csb, .csd, .rube, .po, .obj, .mtl, .udf, .fsh, .vsh, .db, .ogg, .mp3,
  .efk, .efkefc, .txt) and anything Prism doesn't explicitly know about,
  since unknown extensions just fall through to the binary path.
]]
function Builder.applyLayer(gamePackageDir, manifest, relPath, packId, priority, srcAbsolutePath)
    local destPath = gamePackageDir .. "/" .. relPath
    local fileEntry = manifest.files[relPath]
    local isJson = relPath:match("%.json$") ~= nil

    if not fileEntry then
        local existed = io.open(destPath, "rb")
        local hadOriginal = existed ~= nil
        if existed then existed:close() end

        if hadOriginal then
            local backupPath = gamePackageDir .. "/" .. PRISM_BACKUP_DIR .. "/" .. relPath
            local ok, err = copyFile(destPath, backupPath)
            if not ok then
                return false, "Failed to back up original " .. relPath .. ": " .. tostring(err)
            end
        end

        fileEntry = { hadOriginal = hadOriginal, layers = {} }

        if isJson and hadOriginal then
            local baseFile = io.open(destPath, "rb")
            local baseContent = baseFile:read("*a")
            baseFile:close()
            local baseDecodeOk, baseDecoded = pcall(Json.decode, baseContent)
            if baseDecodeOk and type(baseDecoded) == "table" then
                fileEntry.mergeType = "array_append"
                fileEntry.baseArray = baseDecoded
            end
        elseif isJson and not hadOriginal then
            -- no original to probe against; tentatively flag as
            -- array-mergeable and let the pack-content probe below
            -- confirm or fall back to binary
            fileEntry.mergeType = "array_append"
            fileEntry.baseArray = {}
        end

        manifest.files[relPath] = fileEntry
    end

    if fileEntry.mergeType == "array_append" then
        local packFile = io.open(srcAbsolutePath, "rb")
        local packContent = packFile:read("*a")
        packFile:close()
        local packDecodeOk, packDecoded = pcall(Json.decode, packContent)

        if not packDecodeOk or type(packDecoded) ~= "table" then
            Log("applyLayer: " .. relPath .. " pack content not decodable as array, falling back to binary layer")
            fileEntry.mergeType = nil
            fileEntry.baseArray = nil
        else
            for i = #fileEntry.layers, 1, -1 do
                if fileEntry.layers[i].packId == packId then
                    table.remove(fileEntry.layers, i)
                end
            end
            table.insert(fileEntry.layers, { packId = packId, priority = priority, addedEntries = packDecoded })
            return Builder.resolveJsonArrayFile(gamePackageDir, relPath, fileEntry)
        end
    end

    -- binary/opaque layer path
    local layerPath = gamePackageDir .. "/" .. PRISM_LAYERS_DIR .. "/" .. packId .. "/" .. relPath
    local ok, err = copyFile(srcAbsolutePath, layerPath)
    if not ok then
        return false, "Failed to preserve layer content for " .. relPath .. ": " .. tostring(err)
    end

    for i = #fileEntry.layers, 1, -1 do
        if fileEntry.layers[i].packId == packId then
            table.remove(fileEntry.layers, i)
        end
    end
    table.insert(fileEntry.layers, { packId = packId, priority = priority, appliedPath = layerPath })

    return Builder.resolveBinaryFile(gamePackageDir, relPath, fileEntry)
end

--[[
  Builder.removeLayer(gamePackageDir, manifest, packId)

  Removes every layer belonging to packId across every file this
  package's manifest tracks, re-resolving each affected file afterward -
  restoring the original, falling through to the next-highest remaining
  layer, or deleting the file, whichever applies. Files this pack never
  touched are left completely alone.

  Returns the count of files that were actually affected, so callers can
  decide whether this package needs its .packages entry rebuilt.
]]
function Builder.removeLayer(gamePackageDir, manifest, packId)
    local affected = 0

    for relPath, fileEntry in pairs(manifest.files) do
        local touchedThisFile = false
        for i = #fileEntry.layers, 1, -1 do
            if fileEntry.layers[i].packId == packId then
                local layer = fileEntry.layers[i]
                if layer.appliedPath then
                    File(layer.appliedPath):delete()
                end
                table.remove(fileEntry.layers, i)
                touchedThisFile = true
            end
        end

        if touchedThisFile then
            affected = affected + 1
            local ok, err = Builder.resolveFile(gamePackageDir, relPath, fileEntry)
            if not ok then
                Log("removeLayer: WARNING failed to resolve " .. relPath .. " after removing " .. packId .. ": " .. tostring(err))
            end

            if #fileEntry.layers == 0 then
                manifest.files[relPath] = nil
            end
        end
    end

    Log("removeLayer: " .. packId .. " removed from " .. gamePackageDir .. ", " .. tostring(affected) .. " file(s) affected")
    return affected
end

--[[
  Builder.reorderLayers(gamePackageDir, manifest, newPriorityByPackId)

  Updates every layer's priority across every tracked file in this
  package according to newPriorityByPackId ({ [packId] = priority }),
  then re-resolves every affected file. Layers belonging to a packId not
  present in newPriorityByPackId are left untouched (their relative
  priority vs. everything else is preserved as-is).

  Returns the count of files that were actually re-resolved (i.e. whose
  set of touching packIds intersected newPriorityByPackId).
]]
function Builder.reorderLayers(gamePackageDir, manifest, newPriorityByPackId)
    local affected = 0

    for relPath, fileEntry in pairs(manifest.files) do
        local touchedThisFile = false
        for _, layer in ipairs(fileEntry.layers) do
            local newPriority = newPriorityByPackId[layer.packId]
            if newPriority ~= nil then
                layer.priority = newPriority
                touchedThisFile = true
            end
        end

        if touchedThisFile then
            affected = affected + 1
            local ok, err = Builder.resolveFile(gamePackageDir, relPath, fileEntry)
            if not ok then
                Log("reorderLayers: WARNING failed to resolve " .. relPath .. ": " .. tostring(err))
            end
        end
    end

    Log("reorderLayers: " .. gamePackageDir .. ", " .. tostring(affected) .. " file(s) re-resolved")
    return affected
end



--[[
  Builder.mergeJsonArrays(basePath, packPath)

  Reads two JSON files that are both top-level arrays, and returns a new
  array containing all of base's entries followed by all of pack's entries.
  This is the "append, don't replace" merge strategy from the Prism spec
  (see context: additional_customizations.json example).

  Params:
    basePath (string) - path to the game's original JSON file
    packPath (string) - path to the pack's version of the same JSON file

  Returns:
    merged (table|nil) - the merged array
    err (string|nil)
]]
function Builder.mergeJsonArrays(basePath, packPath)
    local baseFile = io.open(basePath, "rb")
    local baseContent = "[]"
    if baseFile then
        baseContent = baseFile:read("*a")
        baseFile:close()
    else
        Log("mergeJsonArrays: base file missing, treating as empty array: " .. tostring(basePath))
    end

    local packFile = io.open(packPath, "rb")
    if not packFile then
        return nil, "Pack JSON file not found: " .. tostring(packPath)
    end
    local packContent = packFile:read("*a")
    packFile:close()

    local okBase, baseDecoded = pcall(Json.decode, baseContent)
    if not okBase or type(baseDecoded) ~= "table" then
        return nil, "Failed to decode base JSON: " .. tostring(basePath)
    end

    local okPack, packDecoded = pcall(Json.decode, packContent)
    if not okPack or type(packDecoded) ~= "table" then
        return nil, "Failed to decode pack JSON: " .. tostring(packPath)
    end

    local merged = {}
    for i = 1, #baseDecoded do
        merged[#merged + 1] = baseDecoded[i]
    end
    for i = 1, #packDecoded do
        merged[#merged + 1] = packDecoded[i]
    end

    Log("mergeJsonArrays: " .. tostring(#baseDecoded) .. " base + " .. tostring(#packDecoded) .. " pack = " .. tostring(#merged) .. " merged entries")

    return merged
end

--[[
  Builder.resolveVehiclePackage(index, vehicleName)

  Vehicle paint/texture/particle assets are NOT stored in a package named
  after the vehicle - they're bucketed across remote_vehicle_paints.zip,
  remote_vehicle_paints_2.zip, remote_vehicle_paints_3.zip (and potentially
  more in future game updates), keyed by which vehicles happen to share a
  bundle. There's no static vehicle->package table we can hardcode, since
  Fingersoft can reshuffle this bucketing between updates.

  Instead we resolve it dynamically, in two tiers:
    1. Search filelists for an existing "textures/cars/<vehicleName>/" or
       "Particles/cars/<vehicleName>/" path (the vehicle already has at
       least one skin/paint shipped).
    2. Fallback: search for the vehicle's definition file
       (additional_vehicle_<name>.json or vehicle_<name>_model*.json) -
       this covers a vehicle that exists in the game but has no cosmetic
       variants yet, so tier 1 finds nothing.
  If a vehicle's definition is found in more than one package (this
  happens in real data - e.g. "rally" exists in both remote_bomber.zip
  and remote_nikita.zip), resolution is refused rather than guessing.
  If neither tier finds anything, the vehicle likely doesn't exist in the
  game at all (a wholly custom/fictional vehicle), which Prism does not
  currently support - that needs a full vehicle-registration step beyond
  applying textures into an existing package.

  Params:
    index (table)       - result of Loader.readIndex()
    vehicleName (string)- e.g. "jeep", "superjeep"

  Returns:
    packageName (string|nil) - e.g. "remote_vehicle_paints_2.zip"
    err (string|nil)
]]
function Builder.resolveVehiclePackage(index, vehicleName)
    local needles = {
        "textures/cars/" .. vehicleName .. "/",
        "Particles/cars/" .. vehicleName .. "/",
    }

    for i = 1, #index.list do
        local entry = index.list[i]
        if entry.filelist then
            for j = 1, #entry.filelist do
                for k = 1, #needles do
                    if entry.filelist[j]:find(needles[k], 1, true) then
                        Log("resolveVehiclePackage: " .. vehicleName .. " -> " .. entry.name .. " (via existing asset)")
                        return entry.name
                    end
                end
            end
        end
    end

    -- Fallback: the vehicle may exist in the game (has a definition JSON
    -- registered) but has no skins/paints shipped yet - e.g. a base
    -- vehicle before its first cosmetic variant. In that case there's no
    -- textures/cars/ or Particles/cars/ path to search for, but the
    -- vehicle's definition file (additional_vehicle_<name>.json or
    -- vehicle_<name>_model*.json) still tells us which package "owns"
    -- that vehicle's slot.
    local defNeedle = "additional_vehicle_" .. vehicleName .. ".json"
    local modelNeedlePrefix = "vehicle_" .. vehicleName .. "_model"
    local matches = {}

    for i = 1, #index.list do
        local entry = index.list[i]
        if entry.filelist then
            for j = 1, #entry.filelist do
                local f = entry.filelist[j]
                if f:find(defNeedle, 1, true) or f:find(modelNeedlePrefix, 1, true) then
                    matches[entry.name] = true
                    break
                end
            end
        end
    end

    local matchNames = {}
    for name in pairs(matches) do table.insert(matchNames, name) end

    if #matchNames == 1 then
        Log("resolveVehiclePackage: " .. vehicleName .. " -> " .. matchNames[1] .. " (via vehicle definition, no existing skins)")
        return matchNames[1]
    elseif #matchNames > 1 then
        -- Real data confirms this happens (e.g. "rally" appears in both
        -- remote_bomber.zip and remote_nikita.zip) - can't safely guess
        -- which one a new skin belongs in, so surface the ambiguity
        -- rather than silently picking one.
        table.sort(matchNames)
        local list = table.concat(matchNames, ", ")
        Log("resolveVehiclePackage: " .. vehicleName .. " is ambiguous - found in multiple packages: " .. list)
        return nil, "Vehicle '" .. vehicleName .. "' exists in multiple packages (" .. list .. ") - cannot determine target automatically"
    end

    Log("resolveVehiclePackage: no package found containing textures/cars/" .. vehicleName .. "/, Particles/cars/" .. vehicleName .. "/, or a vehicle definition for '" .. vehicleName .. "'")
    return nil, "Vehicle '" .. vehicleName .. "' does not exist in any loaded package (no assets, no definition) - this vehicle may not exist in the game, or may need a full vehicle-registration step Prism doesn't support yet"
end

--[[
  Determines whether a pack-authored file (by extension) belongs under the
  real game's "textures/cars/" or "Particles/cars/" tree. Textures and
  their JSON sidecars (transform.json, particleVariants.json, etc.) live
  under textures/cars/; particle definition/effect files live under
  Particles/cars/ (see remote_vehicle_paints.zip real structure: .plist,
  .csb, .csd, .efk, .udf all live under Particles/cars/<vehicle>/...).
]]
local PARTICLE_EXTENSIONS = {
    plist = true, csb = true, csd = true, efk = true, efkefc = true, udf = true,
}

local function assetPrefixFor(relativePath)
    local ext = relativePath:match("%.([%a]+)$")
    if ext and PARTICLE_EXTENSIONS[ext:lower()] then
        return "Particles/cars/"
    end
    return "textures/cars/"
end

--[[
  Builder.applyVehiclePack(index, vehiclePackFiles)

  Applies a pack's vehicle-paint/particle files (as scanned by
  Loader.scanVehiclePack under a pack's "packages/<vehicle>/<tier>/<skinDir>/..."
  layout) into the real game package that actually owns that vehicle's assets.

  This bridges the simplified authoring convention (vehicle-first paths,
  no need for pack creators to know which remote_vehicle_paints*.zip a
  vehicle lives in, or whether a given file is a texture vs a particle
  effect) with the real game convention of separate textures/cars/ and
  Particles/cars/ trees within the resolved package.

  Params:
    index (table)            - result of Loader.readIndex()
    vehiclePackFiles (table) - flat list of {absolutePath, relativePath}
                                where relativePath is "<vehicle>/<tier>/<skinDir>/<file>",
                                e.g. from Loader.scanVehiclePack (NOT via the
                                packageName-keyed scanPack result, since
                                "jeep" isn't a real package name)
    packId (string)          - the installing pack's manifest id (see
                                Prism manifest.json "id" field), used to
                                tag every touched file's layer so it can
                                later be cleanly removed/reordered
    priority (number)        - this pack's position in the Minecraft-style
                                priority stack; higher wins on conflict

  Returns:
    results (table) - { [vehicleName] = { packageName, ok, err } } per vehicle touched
]]
function Builder.applyVehiclePack(index, vehiclePackFiles, packId, priority)
    -- group files by vehicle (first path segment)
    local byVehicle = {}
    for i = 1, #vehiclePackFiles do
        local file = vehiclePackFiles[i]
        local vehicleName = file.relativePath:match("^([^/]+)/")
        if vehicleName then
            byVehicle[vehicleName] = byVehicle[vehicleName] or {}
            table.insert(byVehicle[vehicleName], file)
        else
            Log("applyVehiclePack: skipping file with no vehicle segment: " .. file.relativePath)
        end
    end

    local results = {}

    for vehicleName, files in pairs(byVehicle) do
        local packageName, resolveErr = Builder.resolveVehiclePackage(index, vehicleName)
        if not packageName then
            results[vehicleName] = { ok = false, err = resolveErr }
        else
            local gamePackageDir = Paths.PACKAGES .. packageName

            -- rewrite relative paths with the correct real prefix per file,
            -- since a single vehicle skin can ship both textures and
            -- particle effects that belong in different real trees
            local rewritten = {}
            for i = 1, #files do
                table.insert(rewritten, {
                    absolutePath = files[i].absolutePath,
                    relativePath = assetPrefixFor(files[i].relativePath) .. files[i].relativePath,
                })
            end

            local ok, applyErr = Builder.applyPackToPackage(packageName, rewritten, gamePackageDir, packId, priority)
            results[vehicleName] = { packageName = packageName, ok = ok, err = applyErr }
        end
    end

    return results
end

--[[
  Builder.applyPackToPackage(packageName, packFiles, gamePackageDir, packId, priority)

  Applies a single pack's files for one game package into the real
  content_cache package directory, routed entirely through the layer
  system (Builder.applyLayer) so every file - JSON-array-mergeable or
  opaque binary - gets tracked per-pack and is cleanly reversible via
  Builder.removeLayer/uninstallPack, and re-orderable via
  Builder.reorderLayers/reorderPacks.

  Loads the package's .prism_manifest.json once up front, applies every
  file against it in memory, then writes the manifest back out once at
  the end - avoids re-reading/re-writing JSON per file for packs with
  many entries (some real packages seen in practice have 300+ files).

  Params:
    packageName (string)   - e.g. "driver_mythic.zip"
    packFiles (table)      - { {absolutePath, relativePath}, ... }
    gamePackageDir (string)- absolute path to the real package dir, e.g.
                              Paths.PACKAGES .. "driver_mythic.zip"
    packId (string)        - installing pack's manifest id
    priority (number)      - installing pack's priority in the stack

  Returns:
    ok (boolean)
    err (string|nil)
]]
function Builder.applyPackToPackage(packageName, packFiles, gamePackageDir, packId, priority)
    Log("applyPackToPackage: " .. tostring(packageName) .. ", " .. tostring(#packFiles) .. " files, packId=" .. tostring(packId) .. ", priority=" .. tostring(priority))

    if not packId then
        return false, "applyPackToPackage requires a packId to track this file's layer"
    end
    priority = priority or 0

    local manifest = Builder.readPackManifest(gamePackageDir)

    for i = 1, #packFiles do
        local file = packFiles[i]
        local ok, err = Builder.applyLayer(gamePackageDir, manifest, file.relativePath, packId, priority, file.absolutePath)
        if not ok then
            Log("applyPackToPackage: failed on " .. file.relativePath .. ": " .. tostring(err))
            -- persist whatever succeeded so far before bailing, so a
            -- partial apply is still tracked and can be cleanly rolled
            -- back by installVehiclePack's backup-restore path rather
            -- than leaving orphaned _prism_layers content with no
            -- manifest entry pointing at it
            Builder.writePackManifest(gamePackageDir, manifest)
            return false, err
        end
    end

    local writeOk, writeErr = Builder.writePackManifest(gamePackageDir, manifest)
    if not writeOk then
        return false, "Applied files but failed to write manifest: " .. tostring(writeErr)
    end

    return true
end

--[[
  Builder.rebuildPackageEntry(packageName, gamePackageDir, existingEntry)

  Rebuilds the filelist for one package by walking its real directory in
  content_cache, after pack files have been applied. Mirrors the shape of
  an original .packages entry.

  IMPORTANT: mirrors the same in-place-mutation fix as writeIndex. If
  existingEntry is provided, we mutate THAT table (only filelist and
  updated) and return it, rather than building a new table with only
  the 5 keys we know about - preserving any per-entry fields the real
  game uses that we haven't seen yet. Only when existingEntry is nil
  (genuinely new package - shouldn't normally happen for a vehicle pack,
  since we resolve into an EXISTING package) do we construct fresh.

  Also stamps entry.prism with a queryable summary of Prism's involvement,
  read directly from the package's manifest (rather than duplicating
  bookkeeping in two places): { managed, packs: [{id, priority}, ...] }.
  This is the ".packages-level marker" - lets anything inspecting a raw
  .packages dump immediately see which packages Prism touched and by
  which packs, without needing to open every package folder and check
  for a .prism_manifest.json sidecar. Kept in sync on every rebuild, so
  it always reflects the manifest's current state (a pack that's been
  fully removed via uninstallPack won't linger in "packs" here since its
  layers - and therefore its presence in the manifest - are already gone
  by the time rebuildPackageEntry runs).

  Params:
    packageName (string)    - e.g. "driver_mythic.zip"
    gamePackageDir (string) - absolute path to the package's real directory
    existingEntry (table|nil) - the original .packages entry for this
                                 package, if any (mutated in place and
                                 returned when present)

  Returns:
    entry (table) - the same table as existingEntry (mutated), or a fresh
                     minimal one if existingEntry was nil
]]
function Builder.rebuildPackageEntry(packageName, gamePackageDir, existingEntry)
    local filelist = {}

    local function walk(path, base)
        local d = File(path)
        if not d:exists() or not d:isDirectory() then return end
        local entries = d:listFiles()
        if not entries then return end
        for i = 1, #entries do
            local e = entries[i]
            local name = tostring(e:getName())
            -- skip our own scratch/system files (if a caller ever points
            -- this at Paths.PACKAGES by mistake), and Prism's own
            -- bookkeeping (_prism_backup/, _prism_layers/, manifest) -
            -- none of this is real game content and must never appear
            -- in the filelist the game itself reads from .packages
            if not (name:match("^%.checksum_tmp") or name:match("^%.packages_")
                or name == "_prism_backup" or name == "_prism_layers"
                or name == ".prism_manifest.json") then
                if e:isDirectory() then
                    walk(tostring(e:getAbsolutePath()), base)
                else
                    local abs = tostring(e:getAbsolutePath())
                    local rel = abs:sub(#base + 2)
                    table.insert(filelist, rel)
                end
            end
        end
    end
    walk(gamePackageDir, gamePackageDir)
    table.sort(filelist)

    -- Derive the prism summary from the manifest's actual layer stacks
    -- (unique packIds across every tracked file), rather than trusting a
    -- caller-passed list - this way it's always accurate to what's really
    -- on disk, even if rebuildPackageEntry is called standalone (e.g. from
    -- repair tooling) without going through installVehiclePack.
    local manifest = Builder.readPackManifest(gamePackageDir)
    local packSet = {}
    for _, fileEntry in pairs(manifest.files) do
        for _, layer in ipairs(fileEntry.layers) do
            packSet[layer.packId] = layer.priority
        end
    end
    local prismPacks = {}
    for id, priority in pairs(packSet) do
        table.insert(prismPacks, { id = id, priority = priority })
    end
    table.sort(prismPacks, function(a, b) return a.priority < b.priority end)
    local prismSummary = { managed = #prismPacks > 0, packs = prismPacks }

    if existingEntry then
        -- mutate in place: preserves checksum, safeStartupCount, and any
        -- other fields on the real entry we don't explicitly know about
        existingEntry.filelist = filelist
        existingEntry.updated = os.time()
        existingEntry.prism = prismSummary
        Log("rebuildPackageEntry: " .. packageName .. " -> " .. tostring(#filelist) .. " files (mutated existing entry in place), prism.managed=" .. tostring(prismSummary.managed))
        return existingEntry
    end

    local entry = {
        name = packageName,
        checksum = "",
        filelist = filelist,
        updated = os.time(),
        safeStartupCount = 0,
        prism = prismSummary,
    }

    Log("rebuildPackageEntry: " .. packageName .. " -> " .. tostring(#filelist) .. " files, checksum preserved=" .. tostring(entry.checksum ~= ""))

    return entry
end

--[[
  Builder.writeIndex(index)

  Writes the (modified) package index back to .packages: encodes the JSON,
  writes it to a scratch decrypted file, then re-encrypts it in place using
  the SAME cryptoMeta Loader.readIndex captured from Crypto.decrypt - this
  is required, not optional (see note at top of file).

  Params:
    index (table) - the index table as returned/mutated from Loader.readIndex,
                     including index.cryptoMeta, index.list, index.lastAssetUpdated,
                     index.listUpdated

  Returns:
    ok (boolean)
    err (string|nil)
]]
function Builder.writeIndex(index)
    if not index.cryptoMeta then
        return false, "index.cryptoMeta missing - cannot encrypt without the meta from Crypto.decrypt"
    end
    if not index.raw then
        return false, "index.raw missing - cannot safely write .packages without the full original decoded object (see readIndex)"
    end

    -- CRITICAL: encode the FULL original object (index.raw), not a
    -- reconstructed subset. index.list is the same table reference as
    -- index.raw.packages, so any entries already replaced in index.list
    -- (e.g. by installVehiclePack) are already reflected here. Only
    -- list_updated is explicitly bumped; everything else in the original
    -- object - including any fields we don't specifically know about -
    -- passes through untouched. Reconstructing a new table from scratch
    -- previously dropped unknown fields and shrank .packages from 296KB
    -- to 109KB, which the game detected as corrupt and auto-restored.
    index.raw.list_updated = os.time()
    if index.lastAssetUpdated then
        index.raw.last_asset_updated = index.lastAssetUpdated
    end
    index.raw.packages = index.list

    local okEncode, encoded = pcall(Json.encode, index.raw)
    if not okEncode then
        return false, "Failed to encode .packages JSON: " .. tostring(encoded)
    end

    Log("writeIndex: encoded " .. tostring(#encoded) .. " chars (full raw object, not reconstructed)")

    -- Safety net: if the re-encoded object is drastically smaller than
    -- what we originally read, something is silently dropping data again
    -- (this exact bug previously shrank .packages from 296KB to 109KB and
    -- the game auto-restored from its own backup after detecting
    -- corruption). Refuse to write rather than risk it a second time.
    if index.originalSize and #encoded < index.originalSize * 0.8 then
        local msg = "encoded size (" .. tostring(#encoded) .. " bytes) is suspiciously smaller than original (" .. tostring(index.originalSize) .. " bytes) - refusing to write, this looks like silent data loss"
        Log("writeIndex: ABORTING - " .. msg)
        return false, msg
    end

    local scratchPath = Paths.PACKAGES .. ".packages_rebuilt"
    local f = io.open(scratchPath, "wb")
    if not f then
        return false, "Cannot write scratch file: " .. scratchPath
    end
    f:write(encoded)
    f:close()

    local ok, err = pcall(function()
        return Crypto.encrypt(scratchPath, Paths.INDEX, index.cryptoMeta)
    end)
    os.remove(scratchPath)

    if not ok or not err then
        Log("writeIndex: encrypt failed: " .. tostring(err))
        return false, "Failed to encrypt .packages: " .. tostring(err)
    end

    Log("writeIndex: wrote " .. tostring(#index.list) .. " entries to " .. Paths.INDEX)
    return true
end

--[[
  Recursively deletes a directory tree. Used to clear a corrupted package
  dir before restoring it from backup.
]]
deleteDirRecursive = function(path)
    local f = File(path)
    if not f:exists() then return true end
    if f:isDirectory() then
        local entries = f:listFiles()
        if entries then
            for i = 1, #entries do
                deleteDirRecursive(tostring(entries[i]:getAbsolutePath()))
            end
        end
    end
    return f.delete and f:delete() or true
end

--[[
  Restores a package directory from its "_backup" copy: deletes whatever
  is currently there (which may be partially/corruptly applied) and
  copies the backup back into place. Used automatically on install
  failure so a bad apply never leaves live game files in a broken state.
]]
restorePackageFromBackup = function(packageName)
    local gamePackageDir = Paths.PACKAGES .. packageName
    local backupDir = Paths.PACKAGES .. packageName .. "_backup"

    if not File(backupDir):exists() then
        Log("restorePackageFromBackup: no backup found for " .. packageName .. ", cannot restore")
        return false, "No backup exists for " .. packageName
    end

    local deleted = deleteDirRecursive(gamePackageDir)
    Log("restorePackageFromBackup: cleared current " .. packageName .. ": " .. tostring(deleted))

    local restored = copyDirRecursive(backupDir, gamePackageDir)
    Log("restorePackageFromBackup: restored " .. packageName .. " from backup: " .. tostring(restored))

    return restored
end

--[[
  Builder.repairZeroByteFiles(gamePackageDir)

  One-off cleanup for a specific failure mode: a previous copyFile bug
  (fixed - see copyFile's comment about colon-call vs dot-call) could
  leave a 0-byte destination file behind if the write half of a copy
  failed after the file was created but before any bytes were written.

  This walks gamePackageDir and DELETES any 0-byte file it finds,
  logging each one. It does NOT attempt to restore correct content,
  since a 0-byte file has no way to recover what it should have
  contained - the caller must re-run the install (with the now-fixed
  copyFile) to regenerate it correctly, or manually restore from a
  known-good backup/reinstall if this is a base-game file, not a
  pack-supplied one.

  Params:
    gamePackageDir (string) - absolute path to scan, e.g.
                               Paths.PACKAGES.."remote_vehicle_paints_2.zip"

  Returns:
    removed (table) - list of relative paths that were deleted
]]
function Builder.repairZeroByteFiles(gamePackageDir)
    local removed = {}

    local function walk(path, base)
        local d = File(path)
        if not d:exists() or not d:isDirectory() then return end
        local entries = d:listFiles()
        if not entries then return end
        for i = 1, #entries do
            local e = entries[i]
            if e:isDirectory() then
                walk(tostring(e:getAbsolutePath()), base)
            else
                local size = e:length()
                if size == 0 then
                    local abs = tostring(e:getAbsolutePath())
                    local rel = abs:sub(#base + 2)
                    Log("repairZeroByteFiles: found 0-byte file, deleting: " .. rel)
                    e:delete()
                    table.insert(removed, rel)
                end
            end
        end
    end
    walk(gamePackageDir, gamePackageDir)

    Log("repairZeroByteFiles: removed " .. tostring(#removed) .. " zero-byte file(s) from " .. gamePackageDir)
    return removed
end

--[[
  Builder.installVehiclePack(index, vehiclePackFiles)

  Full end-to-end install of a vehicle-first pack (as scanned by
  Loader.scanVehiclePack) into the real game files:

    1. For each vehicle, resolve which real package owns it
    2. Back up that package's real directory (Paths.PACKAGES.."<pkg>_backup")
       so a bad apply can be manually restored
    3. Apply the pack's files (JSON arrays merged, everything else copied)
    4. Rebuild that package's .packages entry (fresh filelist, preserved
       checksum/safeStartupCount - see rebuildPackageEntry's checksum note)
    5. Replace the entry in index.list / index.byName
    6. Write the updated index back to .packages via Crypto.encrypt,
       using index.cryptoMeta

  This DOES modify real game files under Paths.PACKAGES and Paths.INDEX.
  SAFETY: if apply, rebuild, or index-write fails partway through, every
  touched package is automatically restored from its "_backup" copy
  before returning, so a failed install never leaves live game files in
  a partially-applied or corrupted state. Backups themselves are left in
  place afterward (not auto-deleted) as an extra manual-recovery option.

  Params:
    index (table)            - result of Loader.readIndex() (mutated in place)
    vehiclePackFiles (table) - result of Loader.scanVehiclePack()
    packId (string)          - installing pack's manifest id; every file this
                                install touches is tagged with this id so it
                                can later be individually uninstalled or
                                reordered via Builder.uninstallPack /
                                Builder.reorderPacks without affecting any
                                other pack layered on the same package
    priority (number|nil)    - this pack's position in the priority stack.
                                If nil, defaults to "install on top": one
                                more than the highest existing priority
                                found across all target packages' manifests
                                (i.e. new installs land at the top of the
                                stack by default, matching how adding a new
                                resource pack in Minecraft puts it at the
                                top of the list unless manually reordered)

  Returns:
    ok (boolean)
    report (table) - { perVehicle = {...}, indexWritten = bool, err = string|nil }
]]
function Builder.installVehiclePack(index, vehiclePackFiles, packId, priority)
    if not index or not index.cryptoMeta then
        return false, { err = "index.cryptoMeta missing - refusing to proceed without a valid decrypt meta" }
    end
    if not packId then
        return false, { err = "packId is required - every install must be attributable to a pack for uninstall/reorder to work" }
    end

    -- Resolve target packages first (read-only) so we can back them up
    -- BEFORE any file is touched.
    local byVehicle = {}
    for i = 1, #vehiclePackFiles do
        local file = vehiclePackFiles[i]
        local vehicleName = file.relativePath:match("^([^/]+)/")
        if vehicleName then
            byVehicle[vehicleName] = true
        end
    end

    local targetPackages = {}
    for vehicleName in pairs(byVehicle) do
        local packageName = Builder.resolveVehiclePackage(index, vehicleName)
        if packageName then
            targetPackages[packageName] = true
        end
    end

    for packageName in pairs(targetPackages) do
        local gamePackageDir = Paths.PACKAGES .. packageName
        local backupDir = Paths.PACKAGES .. packageName .. "_backup"
        if not File(backupDir):exists() then
            local backedUp = copyDirRecursive(gamePackageDir, backupDir)
            Log("installVehiclePack: backed up " .. packageName .. " -> " .. packageName .. "_backup: " .. tostring(backedUp))
        else
            Log("installVehiclePack: backup already exists for " .. packageName .. ", not overwriting")
        end
    end

    -- Default priority: land on top of the stack. Scan every target
    -- package's manifest for the current highest priority in use and go
    -- one above it, so a fresh install always wins conflicts against
    -- whatever's already there, same as Minecraft placing a newly added
    -- resource pack at the top of the list.
    if priority == nil then
        local highest = -1
        for packageName in pairs(targetPackages) do
            local manifest = Builder.readPackManifest(Paths.PACKAGES .. packageName)
            for _, fileEntry in pairs(manifest.files) do
                for _, layer in ipairs(fileEntry.layers) do
                    if layer.priority > highest then highest = layer.priority end
                end
            end
        end
        priority = highest + 1
        Log("installVehiclePack: no priority given, defaulting to top of stack: " .. tostring(priority))
    end

    local applyResults = Builder.applyVehiclePack(index, vehiclePackFiles, packId, priority)

    -- collect which packages were actually touched (successfully) so we
    -- only rebuild/backup those, and only proceed to write the index if
    -- at least one package was actually modified
    local touchedPackages = {}
    local anyFailure = false

    for vehicleName, result in pairs(applyResults) do
        if result.ok and result.packageName then
            touchedPackages[result.packageName] = true
            Log("installVehiclePack: " .. vehicleName .. " applied into " .. result.packageName)
        else
            anyFailure = true
            Log("installVehiclePack: " .. vehicleName .. " FAILED: " .. tostring(result.err))
        end
    end

    if anyFailure then
        Log("installVehiclePack: apply failed, rolling back all target packages")
        for packageName in pairs(targetPackages) do
            restorePackageFromBackup(packageName)
        end
        return false, { perVehicle = applyResults, indexWritten = false, rolledBack = true, err = "one or more vehicles failed to apply, rolled back to backup" }
    end

    local touchedCount = 0
    for _ in pairs(touchedPackages) do touchedCount = touchedCount + 1 end
    if touchedCount == 0 then
        return false, { perVehicle = applyResults, indexWritten = false, err = "no packages were modified" }
    end

    for packageName in pairs(touchedPackages) do
        local gamePackageDir = Paths.PACKAGES .. packageName
        local existingEntry = index.byName[packageName]
        -- rebuildPackageEntry mutates existingEntry in place (when present)
        -- and returns the SAME table reference, so index.list/byName
        -- already reflect the change automatically - no manual splice
        -- needed. This preserves any per-entry fields we don't know about,
        -- fixing the 296KB -> 109KB data-loss bug from reconstructing
        -- entries from scratch.
        Builder.rebuildPackageEntry(packageName, gamePackageDir, existingEntry)
    end

    local writeOk, writeErr = Builder.writeIndex(index)
    if not writeOk then
        Log("installVehiclePack: index write failed, rolling back all touched packages")
        for packageName in pairs(touchedPackages) do
            restorePackageFromBackup(packageName)
        end
        return false, { perVehicle = applyResults, indexWritten = false, rolledBack = true, err = "index write failed: " .. tostring(writeErr) }
    end

    Log("installVehiclePack: done, " .. tostring(touchedCount) .. " package(s) updated and index written")
    return true, { perVehicle = applyResults, indexWritten = true, touchedPackages = touchedPackages }
end


--[[
  Builder.uninstallPack(index, packId)

  Fully reverses one pack's install: finds every real package
  Prism-managed with a layer belonging to packId (via each entry's
  entry.prism.packs - the .packages-level marker, so this doesn't need
  to walk the whole packages/ directory tree looking for manifests),
  removes that pack's layer from every file it touched, and re-resolves
  each affected file to whatever the next-highest remaining layer is (or
  the true original, or deletion, per Builder.removeLayer/resolveFile).

  Crucially, packages still layered by OTHER packs are left correctly
  showing those other packs' content - this is the "uninstall the middle
  pack of three, the top pack's edit still shows" behavior, since
  removeLayer only strips packId's own layer and resolveFile always
  picks whatever the current top layer is, not "the original."

  SAFETY: mirrors installVehiclePack's backup/rollback pattern. Every
  target package is snapshotted (via its existing _backup mechanism, if
  not already present) before any layer removal, and rolled back
  automatically if rebuild/write fails partway through.

  Params:
    index (table)  - result of Loader.readIndex() (mutated in place)
    packId (string)- the pack to uninstall, matched against each real
                     package entry's entry.prism.packs[].id

  Returns:
    ok (boolean)
    report (table) - { touchedPackages = {...}, indexWritten = bool, err = string|nil }
]]
function Builder.uninstallPack(index, packId)
    if not index or not index.cryptoMeta then
        return false, { err = "index.cryptoMeta missing - refusing to proceed without a valid decrypt meta" }
    end
    if not packId then
        return false, { err = "packId is required" }
    end

    -- Find every package this pack touched by reading the .packages-level
    -- prism marker directly - no directory walk needed.
    local targetPackages = {}
    for i = 1, #index.list do
        local entry = index.list[i]
        if entry.prism and entry.prism.packs then
            for _, p in ipairs(entry.prism.packs) do
                if p.id == packId then
                    targetPackages[entry.name] = true
                    break
                end
            end
        end
    end

    local targetCount = 0
    for _ in pairs(targetPackages) do targetCount = targetCount + 1 end
    if targetCount == 0 then
        Log("uninstallPack: " .. packId .. " not found in any package's prism.packs, nothing to do")
        return false, { err = "Pack '" .. packId .. "' is not installed in any tracked package" }
    end

    for packageName in pairs(targetPackages) do
        local gamePackageDir = Paths.PACKAGES .. packageName
        local backupDir = Paths.PACKAGES .. packageName .. "_backup"
        if not File(backupDir):exists() then
            local backedUp = copyDirRecursive(gamePackageDir, backupDir)
            Log("uninstallPack: backed up " .. packageName .. " -> " .. packageName .. "_backup: " .. tostring(backedUp))
        else
            Log("uninstallPack: backup already exists for " .. packageName .. ", not overwriting")
        end
    end

    local touchedPackages = {}
    local anyFailure = false
    local perPackage = {}

    for packageName in pairs(targetPackages) do
        local gamePackageDir = Paths.PACKAGES .. packageName
        local manifest = Builder.readPackManifest(gamePackageDir)
        local affected = Builder.removeLayer(gamePackageDir, manifest, packId)

        local writeOk, writeErr = Builder.writePackManifest(gamePackageDir, manifest)
        if not writeOk then
            anyFailure = true
            perPackage[packageName] = { ok = false, err = writeErr }
            Log("uninstallPack: " .. packageName .. " FAILED to write manifest: " .. tostring(writeErr))
        else
            touchedPackages[packageName] = true
            perPackage[packageName] = { ok = true, filesAffected = affected }
        end
    end

    if anyFailure then
        Log("uninstallPack: manifest write failed, rolling back all target packages")
        for packageName in pairs(targetPackages) do
            restorePackageFromBackup(packageName)
        end
        return false, { perPackage = perPackage, indexWritten = false, rolledBack = true, err = "one or more packages failed to update, rolled back to backup" }
    end

    for packageName in pairs(touchedPackages) do
        local gamePackageDir = Paths.PACKAGES .. packageName
        local existingEntry = index.byName[packageName]
        -- same in-place mutation as installVehiclePack: rebuildPackageEntry
        -- also recomputes entry.prism from the (now-updated) manifest, so
        -- packId is automatically dropped from entry.prism.packs here,
        -- and entry.prism.managed flips to false if no packs remain
        Builder.rebuildPackageEntry(packageName, gamePackageDir, existingEntry)
    end

    local writeOk, writeErr = Builder.writeIndex(index)
    if not writeOk then
        Log("uninstallPack: index write failed, rolling back all touched packages")
        for packageName in pairs(touchedPackages) do
            restorePackageFromBackup(packageName)
        end
        return false, { perPackage = perPackage, indexWritten = false, rolledBack = true, err = "index write failed: " .. tostring(writeErr) }
    end

    Log("uninstallPack: done, " .. packId .. " removed from " .. tostring(targetCount) .. " package(s)")
    return true, { perPackage = perPackage, indexWritten = true, touchedPackages = touchedPackages }
end

--[[
  Builder.reorderPacks(index, orderedPackIds)

  Re-orders the priority stack across ALL Prism-managed packages at
  once, Minecraft-style: orderedPackIds is a list from lowest to highest
  priority (matching the "Lowest Priority ... Highest Priority" framing
  in the Prism spec), and every layer belonging to each packId across
  every touched package is updated to that new priority, then
  re-resolved. This never adds or removes a layer - it only changes
  which layer wins where multiple packs touch the same file, and is
  purely a replay against already-preserved _prism_layers content, so it
  works even if a pack's original source folder no longer exists on
  disk.

  Any packId Prism knows about (present in some package's prism.packs)
  but NOT included in orderedPackIds is left with its current priority
  untouched, rather than erroring - lets a caller reorder a subset
  without needing to enumerate every installed pack.

  Params:
    index (table)         - result of Loader.readIndex() (mutated in place)
    orderedPackIds (table)- array of packId strings, index 1 = lowest
                             priority, index #orderedPackIds = highest

  Returns:
    ok (boolean)
    report (table) - { touchedPackages = {...}, indexWritten = bool, err = string|nil }
]]
function Builder.reorderPacks(index, orderedPackIds)
    if not index or not index.cryptoMeta then
        return false, { err = "index.cryptoMeta missing - refusing to proceed without a valid decrypt meta" }
    end
    if not orderedPackIds or #orderedPackIds == 0 then
        return false, { err = "orderedPackIds must be a non-empty array" }
    end

    local newPriorityByPackId = {}
    for i, packId in ipairs(orderedPackIds) do
        newPriorityByPackId[packId] = i
    end

    -- find every package touched by ANY of the reordered packs
    local targetPackages = {}
    for i = 1, #index.list do
        local entry = index.list[i]
        if entry.prism and entry.prism.packs then
            for _, p in ipairs(entry.prism.packs) do
                if newPriorityByPackId[p.id] ~= nil then
                    targetPackages[entry.name] = true
                    break
                end
            end
        end
    end

    local targetCount = 0
    for _ in pairs(targetPackages) do targetCount = targetCount + 1 end
    if targetCount == 0 then
        Log("reorderPacks: none of the given packIds are installed in any tracked package")
        return false, { err = "None of the given pack ids are currently installed" }
    end

    for packageName in pairs(targetPackages) do
        local gamePackageDir = Paths.PACKAGES .. packageName
        local backupDir = Paths.PACKAGES .. packageName .. "_backup"
        if not File(backupDir):exists() then
            copyDirRecursive(gamePackageDir, backupDir)
        end
    end

    local touchedPackages = {}
    local anyFailure = false
    local perPackage = {}

    for packageName in pairs(targetPackages) do
        local gamePackageDir = Paths.PACKAGES .. packageName
        local manifest = Builder.readPackManifest(gamePackageDir)
        local affected = Builder.reorderLayers(gamePackageDir, manifest, newPriorityByPackId)

        local writeOk, writeErr = Builder.writePackManifest(gamePackageDir, manifest)
        if not writeOk then
            anyFailure = true
            perPackage[packageName] = { ok = false, err = writeErr }
        else
            touchedPackages[packageName] = true
            perPackage[packageName] = { ok = true, filesAffected = affected }
        end
    end

    if anyFailure then
        Log("reorderPacks: manifest write failed, rolling back all target packages")
        for packageName in pairs(targetPackages) do
            restorePackageFromBackup(packageName)
        end
        return false, { perPackage = perPackage, indexWritten = false, rolledBack = true, err = "one or more packages failed to update, rolled back to backup" }
    end

    for packageName in pairs(touchedPackages) do
        local gamePackageDir = Paths.PACKAGES .. packageName
        local existingEntry = index.byName[packageName]
        Builder.rebuildPackageEntry(packageName, gamePackageDir, existingEntry)
    end

    local writeOk, writeErr = Builder.writeIndex(index)
    if not writeOk then
        Log("reorderPacks: index write failed, rolling back all touched packages")
        for packageName in pairs(touchedPackages) do
            restorePackageFromBackup(packageName)
        end
        return false, { perPackage = perPackage, indexWritten = false, rolledBack = true, err = "index write failed: " .. tostring(writeErr) }
    end

    Log("reorderPacks: done, " .. tostring(targetCount) .. " package(s) re-resolved")
    return true, { perPackage = perPackage, indexWritten = true, touchedPackages = touchedPackages }
end

return Builder