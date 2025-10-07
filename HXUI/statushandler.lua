-- Pulled from statustimers - Copyright (c) 2022 Heals

-------------------------------------------------------------------------------
-- imports
-------------------------------------------------------------------------------
local d3d8 = require('d3d8');
local ffi = require('ffi');
local imgui = require('imgui');
local encoding = require('gdifonts.encoding');
-------------------------------------------------------------------------------
-- local state
-------------------------------------------------------------------------------
local d3d8_device = d3d8.get_device();
-------------------------------------------------------------------------------
-- local constants
-------------------------------------------------------------------------------
local icon_cache = T{
};

local buffIcon = nil;
local debuffIcon = nil;

local jobIcons = T{};

-- this table implements overrides for certain icons to handle
-- local buffs_table = nil;
local id_overrides = T{
};
-------------------------------------------------------------------------------
-- local functions
-------------------------------------------------------------------------------

-- load a dummy icon placeholder for a missing status and return a texture pointer
---@return ffi.cdata* texture_ptr the loaded texture object or nil on error
local function load_dummy_icon()
    local icon_path = ('%s\\addons\\%s\\ladybug.png'):fmt(AshitaCore:GetInstallPath(), 'statustimers');
    local dx_texture_ptr = ffi.new('IDirect3DTexture8*[1]');

    if (ffi.C.D3DXCreateTextureFromFileA(d3d8_device, icon_path, dx_texture_ptr) == ffi.C.S_OK) then
        return d3d8.gc_safe_release(ffi.cast('IDirect3DTexture8*', dx_texture_ptr[0]));
    end

    return nil;
end

-- load a status icon from the games own resources and return a texture pointer
---@param status_id number the status id to load the icon for
---@return ffi.cdata* texture_ptr the loaded texture object or nil on error
local function load_status_icon_from_resource(status_id)
    if (status_id == nil or status_id < 0 or status_id > 0x3FF) then
        return nil;
    end

    local id_key = ("_%d"):fmt(status_id);
    if (id_overrides:haskey(id_key)) then
        status_id = id_overrides[id_key];
    end

    local icon = AshitaCore:GetResourceManager():GetStatusIconByIndex(status_id);
    if (icon ~= nil) then
        local dx_texture_ptr = ffi.new('IDirect3DTexture8*[1]');
        if (ffi.C.D3DXCreateTextureFromFileInMemoryEx(d3d8_device, icon.Bitmap, icon.ImageSize, 0xFFFFFFFF, 0xFFFFFFFF, 1, 0, ffi.C.D3DFMT_A8R8G8B8, ffi.C.D3DPOOL_MANAGED, ffi.C.D3DX_DEFAULT, ffi.C.D3DX_DEFAULT, 0xFF000000, nil, nil, dx_texture_ptr) == ffi.C.S_OK) then
            return d3d8.gc_safe_release(ffi.cast('IDirect3DTexture8*', dx_texture_ptr[0]));
        end
    end
    return load_dummy_icon();
end

-- load a status icon from a theme pack and return a texture pointer
---@param theme string path to the theme's root directory
---@param status_id number the status id to load the icon for
---@return ffi.cdata* texture_ptr the loaded texture object or nil on error
local function load_status_icon_from_theme(theme, status_id)
    if (status_id == nil or status_id < 0 or status_id > 0x3FF) then
        return nil;
    end

    local icon_path = nil;
    local supports_alpha = false;
    T{'.png', '.jpg', '.jpeg', '.bmp'}:forieach(function(ext, _)
        if (icon_path ~= nil) then
            return;
        end

        supports_alpha = ext == '.png';
        icon_path = ('%s\\assets\\status\\%s\\%d'):append(ext):fmt(addon.path, theme, status_id);
        local handle = io.open(icon_path, 'r');
        if (handle ~= nil) then
            handle.close();
        else
            icon_path = nil;
        end
    end);

    if (icon_path == nil) then
        -- fallback to internal icon resources
        return load_status_icon_from_resource(status_id);
    end

    local dx_texture_ptr = ffi.new('IDirect3DTexture8*[1]');
    if (supports_alpha) then
        -- use the native transaparency
        if (ffi.C.D3DXCreateTextureFromFileA(d3d8_device, icon_path, dx_texture_ptr) == ffi.C.S_OK) then
            return d3d8.gc_safe_release(ffi.cast('IDirect3DTexture8*', dx_texture_ptr[0]));
        end
    else
        -- use black as colour-key for transparency
        if (ffi.C.D3DXCreateTextureFromFileExA(d3d8_device, icon_path, 0xFFFFFFFF, 0xFFFFFFFF, 1, 0, ffi.C.D3DFMT_A8R8G8B8, ffi.C.D3DPOOL_MANAGED, ffi.C.D3DX_DEFAULT, ffi.C.D3DX_DEFAULT, 0xFF000000, nil, nil, dx_texture_ptr) == ffi.C.S_OK) then
            return d3d8.gc_safe_release(ffi.cast('IDirect3DTexture8*', dx_texture_ptr[0]));
        end
    end

    return load_dummy_icon();
end

local ptrPartyBuffs = ashita.memory.find('FFXiMain.dll', 0, 'B93C0000008D7004BF????????F3A5', 9, 0);
ptrPartyBuffs = ashita.memory.read_uint32(ptrPartyBuffs);

-- Call once at plugin load and keep reference to table
local function ReadPartyBuffsFromMemory()
    local ptrPartyBuffs = ashita.memory.read_uint32(AshitaCore:GetPointerManager():Get('party.statusicons'));
    local partyBuffTable = {};
    for memberIndex = 0,4 do
        local memberPtr = ptrPartyBuffs + (0x30 * memberIndex);
        local playerId = ashita.memory.read_uint32(memberPtr);
        if (playerId ~= 0) then
            local buffs = {};
            local empty = false;
            for buffIndex = 0,31 do
                if empty then
                    buffs[buffIndex + 1] = -1;
                else
                    local highBits = ashita.memory.read_uint8(memberPtr + 8 + (math.floor(buffIndex / 4)));
                    local fMod = math.fmod(buffIndex, 4) * 2;
                    highBits = bit.lshift(bit.band(bit.rshift(highBits, fMod), 0x03), 8);
                    local lowBits = ashita.memory.read_uint8(memberPtr + 16 + buffIndex);
                    local buff = highBits + lowBits;
                    if buff == 255 then
                        empty = true;
                        buffs[buffIndex + 1] = -1;
                    else
                        buffs[buffIndex + 1] = buff;
                    end
                end
            end
            partyBuffTable[playerId] = buffs;
        end
    end
    return partyBuffTable;
end
local partyBuffs = ReadPartyBuffsFromMemory();

-------------------------------------------------------------------------------
-- exported functions
-------------------------------------------------------------------------------
local statusHandler = {};

-- return a list of all sub directories
---@return table theme_paths
statusHandler.get_job_theme_paths = function()
    local path = ('%s\\addons\\%s\\assets\\jobs\\'):fmt(AshitaCore:GetInstallPath(), 'HXUI');
    local directories = ashita.fs.get_directory(path);
    if (directories ~= nil) then
        directories[#directories+1] = '-None-';
        return directories;
    end
    return T{'-None-'};
end

-- render the tooltip for a specific status id
---@param status number the status id
---@param is_target boolean if true, don't show '(right click to cancel)' hint
statusHandler.render_tooltip = function(status)
    if (status == nil or status < 1 or status > 0x3FF or status == 255) then
        return;
    end

    local resMan = AshitaCore:GetResourceManager();
    local info = resMan:GetStatusIconByIndex(status);
    local name = resMan:GetString('buffs.names', status);
    if (name ~= nil and info ~= nil) then
        imgui.BeginTooltip();
            imgui.SetWindowFontScale(gConfig.tooltipScale);
            imgui.Text(('%s (#%d)'):fmt(encoding:ShiftJIS_To_UTF8(name, true), status));
            if (info.Description[1] ~= nil) then
                imgui.Text(encoding:ShiftJIS_To_UTF8(info.Description[1], true));
            end
            imgui.SetWindowFontScale(1);
        imgui.EndTooltip();
    end
end

-- return a list of all sub directories
---@return table theme_paths
statusHandler.get_status_theme_paths = function()
    local path = ('%s\\addons\\%s\\assets\\status\\'):fmt(AshitaCore:GetInstallPath(), 'HXUI');
    local directories = ashita.fs.get_directory(path);
    if (directories ~= nil) then
        directories[#directories+1] = '-Default-';
        return directories;
    end
    return T{'-Default-'};
end 

-- return a list of all sub directories
---@return table theme_paths
statusHandler.get_background_paths = function()
    local path = ('%s\\addons\\%s\\assets\\backgrounds\\'):fmt(AshitaCore:GetInstallPath(), 'HXUI');
    local directories = ashita.fs.get_dir(path, '.*.png', true);
    if (directories ~= nil) then
        local backgrounds = { '-None-' };
        for _, filename in ipairs(directories) do
            local bg_name = filename:match('(.+)%-bg.png');
            if bg_name ~= nil then
                table.insert(backgrounds, bg_name);
            end
        end
        return backgrounds;
    end
    return T{};
end 

-- return a list of all sub directories
---@return table theme_paths
statusHandler.get_cursor_paths = function()
    local path = ('%s\\addons\\%s\\assets\\cursors\\'):fmt(AshitaCore:GetInstallPath(), 'HXUI');
    local directories = ashita.fs.get_dir(path, '.*.png', true);
    if (directories ~= nil) then
        return directories;
    end
    return T{};
end 

-- return an image pointer for a status_id for use with imgui.Image
---@param status_id number the status id number of the requested icon
---@return number texture_ptr_id a number representing the texture_ptr or nil
statusHandler.get_icon_image = function(status_id)
    if (not icon_cache:haskey(status_id)) then
        local tex_ptr = load_status_icon_from_resource(status_id);
        if (tex_ptr == nil) then
            return nil;
        end
        icon_cache[status_id] = tex_ptr;
    end
    return tonumber(ffi.cast("uint32_t", icon_cache[status_id]));
end

-- return an image pointer for a status_id for use with imgui.Image
---@param theme string the name of the theme directory
---@param status_id number the status id number of the requested icon
---@return number texture_ptr_id a number representing the texture_ptr or nil
statusHandler.get_icon_from_theme = function(theme, status_id)
    if (not icon_cache:haskey(status_id)) then
        local tex_ptr = load_status_icon_from_theme(theme, status_id);
        if (tex_ptr == nil) then
            return nil;
        end
        icon_cache[status_id] = tex_ptr;
    end
    return tonumber(ffi.cast("uint32_t", icon_cache[status_id]));
end

-- return index of the currently active theme in module.get_theme_paths()
---@return number theme_index
statusHandler.get_theme_index = function(theme)
    local paths = statusHandler.get_theme_paths();
    for i = 1,#paths,1 do
        if (paths[i] == theme) then
            return i;
        end
    end
    return nil;
end

-- reset the icon cache and release all resources
statusHandler.clear_cache = function()
    icon_cache = T{};
    buffIcon = nil;
    debuffIcon = nil;
    jobIcons = T{};
end;

-- return a table of status ids for a party member based on server id.
---@param server_id number the party memer or target server id to check
---@return table status_ids a list of the targets status ids or nil
statusHandler.get_member_status = function(server_id)
    return partyBuffs[server_id];
end

statusHandler.GetBackground = function(isBuff)
    if (isBuff) then
        if (buffIcon == nil) then
            buffIcon = LoadTexture("BuffIcon")
        end
        return tonumber(ffi.cast("uint32_t", buffIcon.image));
    else
        if (debuffIcon == nil) then
            debuffIcon = LoadTexture("DebuffIcon")
        end
        return tonumber(ffi.cast("uint32_t", debuffIcon.image));
    end
end


statusHandler.GetJobIcon = function(jobIdx)

    if (jobIdx == nil or jobIdx == 0 or jobIdx == -1) then
        return nil;
    end

    local jobStr = AshitaCore:GetResourceManager():GetString("jobs.names_abbr", jobIdx);

    if (jobIcons[jobStr] == nil) then
        jobIcons[jobStr] = LoadTexture(string.format('jobs/%s/%s', gConfig.jobIconTheme, jobStr))
    end
    if (jobIcons[jobStr] == nil) then
        return nil;
    end
    return tonumber(ffi.cast("uint32_t", jobIcons[jobStr].image));
end

--Call with incoming packet 0x076
statusHandler.ReadPartyBuffsFromPacket = function(e)
    local partyBuffTable = {};
    for i = 0,4 do
        local memberOffset = 0x04 + (0x30 * i) + 1;
        local memberId = struct.unpack('L', e.data, memberOffset);
        if memberId > 0 then
            local buffs = {};
            local empty = false;
            for j = 0,31 do
                if empty then
                    buffs[j + 1] = -1;
                else
                    --This is at offset 8 from member start.. memberoffset is using +1 for the lua struct.unpacks
                    local highBits = bit.lshift(ashita.bits.unpack_be(e.data_raw, memberOffset + 7, j * 2, 2), 8);
                    local lowBits = struct.unpack('B', e.data, memberOffset + 0x10 + j);
                    local buff = highBits + lowBits;
                    if (buff == 255) then
                        buffs[j + 1] = -1;
                        empty = true;
                    else
                        buffs[j + 1] = buff;
                    end
                end
            end
            partyBuffTable[memberId] = buffs;
        end
    end
    partyBuffs =  partyBuffTable;
end

return statusHandler;
