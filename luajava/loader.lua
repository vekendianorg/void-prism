local Loader = {}

local Prism
local Json
local Crypto
local Paths
local Log

-- Java bindings
local File

function Loader.init(core)
    Prism = core
    Json = core.Json
    Crypto = core.Crypto
    Paths = core.Paths
    Log = core.Log

    File = luajava.bindClass("java.io.File")
end

--[[
  Checks file existence/size the same way Void's event.lua does, via plain
  Lua io rather than the Java bridge - simpler and proven to work.
]]
local function fileExists(path)
    local f = io.open(path, "rb")
    if f then f:close(); return true end
    return false
end

local function fileSize(path)
    local f = io.open(path, "rb")
    if not f then return -1 end
    local size = f:seek("end")
    f:close()
    return size or -1
end

--[[
  Loader.readIndex()

  Reads the game's .packages index file, decrypts it via Prism.Crypto,
  and parses the resulting JSON into a Lua table.

  Returns:
    index (table|nil) - decoded .packages contents, keyed both by
                         numeric order (index.list) and by package
                         name (index.byName) for fast lookup
    err (string|nil)  - error message if reading/decrypting/parsing failed
]]
function Loader.readIndex()
    Log("readIndex: start, path=" .. tostring(Paths.INDEX))

    if not fileExists(Paths.INDEX) then
        Log("readIndex: index file not found")
        return nil, "File does not exist: " .. tostring(Paths.INDEX)
    end
    if fileSize(Paths.INDEX) <= 0 then
        Log("readIndex: index file is empty")
        return nil, "Index file is empty: " .. tostring(Paths.INDEX)
    end

    -- Crypto.decrypt is file-to-file (src, dest) -> meta|nil, matching the
    -- pattern used in modules/ops/event.lua. It is NOT a string transform.
    local decryptedPath = Paths.PACKAGES .. ".packages_decrypted"

    local ok, meta = pcall(function()
        return Crypto.decrypt(Paths.INDEX, decryptedPath)
    end)
    if not ok or not meta then
        Log("readIndex: decrypt failed: " .. tostring(meta))
        return nil, "Failed to decrypt .packages: " .. tostring(meta)
    end
    Log("readIndex: decrypted ok, meta=" .. tostring(meta))

    local decFile = io.open(decryptedPath, "rb")
    if not decFile then
        Log("readIndex: cannot open decrypted file: " .. decryptedPath)
        return nil, "Cannot open decrypted file: " .. decryptedPath
    end

    local decrypted = decFile:read("*a")
    decFile:close()
    os.remove(decryptedPath)

    Log("readIndex: read " .. tostring(#decrypted) .. " chars from decrypted file, prefix=" .. decrypted:sub(1, 40))

    -- Known issue: Crypto.decrypt (AES-CBC) garbles exactly the first
    -- plaintext block (~16 bytes) due to an IV/offset bug on the native
    -- side. Every block after the first decrypts correctly (CBC only
    -- corrupts the single block tied to a bad IV, self-correcting from the
    -- second block onward). Rather than try to byte-patch the corrupted
    -- region back to its original text, we just discard it: find the start
    -- of "list_updated" (the first key we know decrypts cleanly, since it's
    -- past block 1) and rebuild a minimal, valid object from there.
    local cleanStart = decrypted:find('"list_updated"')
    if not cleanStart then
        Log("readIndex: could not locate clean JSON start after corrupted header")
        return nil, "Decrypted .packages header is corrupted and could not be repaired"
    end

    if cleanStart > 1 then
        Log("readIndex: discarding corrupted header (" .. tostring(cleanStart - 1) .. " bytes), rebuilding from list_updated")
        decrypted = "{ " .. decrypted:sub(cleanStart)
    end

    local okDecode, decoded = pcall(Json.decode, decrypted)
    if not okDecode or not decoded then
        Log("readIndex: json decode failed: " .. tostring(decoded))
        return nil, "Failed to parse .packages JSON: " .. tostring(decoded)
    end

    -- Confirmed real .packages shape (verified against an actual on-device
    -- dump): a top-level object, not a bare array.
    --   {
    --     "last_asset_updated": <unix ts>,
    --     "list_updated": <unix ts>,
    --     "packages": [ { name, checksum, filelist, updated, safeStartupCount }, ... ]
    --   }
    if type(decoded) ~= "table" or type(decoded.packages) ~= "table" then
        Log("readIndex: unexpected .packages shape, missing 'packages' array")
        return nil, "Unexpected .packages structure: no 'packages' array found"
    end

    local list = decoded.packages
    Log("readIndex: found " .. tostring(#list) .. " package entries, last_asset_updated=" .. tostring(decoded.last_asset_updated) .. ", list_updated=" .. tostring(decoded.list_updated))

    local index = {
        list = list,
        byName = {},
        lastAssetUpdated = decoded.last_asset_updated,
        listUpdated = decoded.list_updated,
        -- Full decoded object, kept alive so Builder.writeIndex can mutate
        -- the SAME table in place (only touching index.list) and re-encode
        -- it whole, rather than reconstructing a new table from scratch.
        -- Reconstructing from scratch silently drops any top-level or
        -- per-entry fields we didn't know to carry over - this is what
        -- caused .packages to shrink from 296KB to 109KB on write. Mirrors
        -- the proven-working pattern in modules/ops/event.lua, which
        -- decodes the full object, mutates only specific fields, and
        -- re-encodes the same table.
        raw = decoded,
        -- Original decrypted plaintext size, used by Builder.writeIndex as
        -- a sanity check against silent data loss on re-encode.
        originalSize = #decrypted,
        -- Crypto.encrypt requires the same meta object Crypto.decrypt
        -- returned (see modules/ops/event.lua: Crypto.encrypt(src, dest, meta)).
        -- Carried through here so Builder can re-encrypt .packages later
        -- without needing to call Loader.readIndex's internals again.
        cryptoMeta = meta,
    }

    for i = 1, #list do
        local entry = list[i]
        if entry and entry.name then
            index.byName[entry.name] = entry
        end
    end

    Log("readIndex: done, indexed " .. tostring(#list) .. " entries")
    return index, nil
end

--[[
  Recursively lists all files under a directory using java.io.File.

  Params:
    dirPath (string) - absolute path to the directory to scan

  Returns:
    files (table) - flat array of { absolutePath, relativePath } entries,
                     relative to dirPath
]]
local function listFilesRecursive(dirPath, basePath)
    basePath = basePath or dirPath
    local files = {}

    local dir = File(dirPath)
    if not dir:exists() or not dir:isDirectory() then
        Log("listFilesRecursive: not a dir: " .. tostring(dirPath))
        return files
    end

    local entries = dir:listFiles()
    if not entries then
        Log("listFilesRecursive: listFiles() returned nil for " .. tostring(dirPath))
        return files
    end

    for i = 1, #entries do
        local entry = entries[i]
        local absPath = tostring(entry:getAbsolutePath())

        if entry:isDirectory() then
            Log("listFilesRecursive: descending into " .. absPath)
            local nested = listFilesRecursive(absPath, basePath)
            for j = 1, #nested do
                table.insert(files, nested[j])
            end
        else
            -- relative path, stripped of basePath prefix and leading slash
            local relPath = absPath:sub(#basePath + 1):gsub("^/", "")
            Log("listFilesRecursive: found file " .. relPath)
            table.insert(files, {
                absolutePath = absPath,
                relativePath = relPath,
            })
        end
    end

    return files
end

--[[
  Loader.scanPack(packPath)

  Scans a Prism mod pack's packages/ directory and reports which game
  packages it touches and which files it provides for each.

  This does NOT read or modify the game's .packages index - it only
  describes the pack's own contents on disk.

  Params:
    packPath (string) - absolute path to the root of a Prism pack
                         (the folder containing manifest.json)

  Returns:
    packages (table|nil) - {
                              [packageName] = {
                                files = { { absolutePath, relativePath }, ... }
                              },
                              ...
                            }
    err (string|nil)
]]
function Loader.scanPack(packPath)
    Log("scanPack: start, packPath=" .. tostring(packPath))

    local packagesDir = packPath .. "/packages"
    Log("scanPack: packagesDir=" .. packagesDir)

    local dir = File(packagesDir)
    if not dir:exists() or not dir:isDirectory() then
        Log("scanPack: no packages/ dir found")
        return nil, "Pack has no packages/ directory: " .. packagesDir
    end

    local entries = dir:listFiles()
    if not entries then
        Log("scanPack: listFiles() returned nil")
        return nil, "Failed to list packages/ directory: " .. packagesDir
    end

    Log("scanPack: found " .. tostring(#entries) .. " entries in packages/")

    local packages = {}

    for i = 1, #entries do
        local entry = entries[i]
        if entry:isDirectory() then
            local packageName = tostring(entry:getName())
            local absPath = tostring(entry:getAbsolutePath())
            Log("scanPack: found package dir " .. packageName)

            packages[packageName] = {
                files = listFilesRecursive(absPath, absPath),
            }
            Log("scanPack: " .. packageName .. " -> " .. tostring(#packages[packageName].files) .. " files")
        else
            Log("scanPack: skipping non-directory entry " .. tostring(entry:getName()))
        end
    end

    Log("scanPack: done, " .. tostring(#entries) .. " entries scanned")
    return packages, nil
end

--[[
  Loader.scanVehiclePack(packPath)

  Scans a pack folder that uses the simplified vehicle-first authoring
  convention: packages/<vehicle>/<tier>/<skinDir>/<file>, mirroring the
  real game's textures/cars/<vehicle>/<tier>/<skinDir>/ layout minus the
  "textures/cars/" prefix and without needing the pack author to know
  which remote_vehicle_paints*.zip a vehicle actually lives in.

  Unlike scanPack(), this does NOT treat the top-level dir as a package
  name (vehicle names like "jeep" aren't real .packages entries) - it just
  returns a flat file list for Builder.applyVehiclePack to group and
  resolve.

  Params:
    packPath (string) - absolute path to the pack's root folder

  Returns:
    files (table|nil) - flat list of {absolutePath, relativePath}, where
                         relativePath is "<vehicle>/<tier>/<skinDir>/<file>"
    err (string|nil)
]]
function Loader.scanVehiclePack(packPath)
    Log("scanVehiclePack: start, packPath=" .. tostring(packPath))

    local packagesDir = packPath .. "/packages"
    local dir = File(packagesDir)
    if not dir:exists() or not dir:isDirectory() then
        Log("scanVehiclePack: no packages/ dir found")
        return nil, "Pack has no packages/ directory: " .. packagesDir
    end

    local files = listFilesRecursive(packagesDir, packagesDir)
    Log("scanVehiclePack: done, " .. tostring(#files) .. " files found")

    return files, nil
end

return Loader
