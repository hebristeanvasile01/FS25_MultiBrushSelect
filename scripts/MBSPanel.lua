Logging.info('[MultiBrushSelect] MBSPanel.lua loaded')
-- Ctrl+O: separate multi-select GUI (textures, foliage, trees; everything the construction menu knows,
-- base game + DLC + mods + every tree type/stage/variation). Click items to toggle them, hold LMB on the
-- terrain to paint / scatter everything selected, mixed.

MBSPanel = {
    active = false,
    selected = {},      -- key -> entry
    selectedCount = 0,
    data = nil,         -- { texture = {...}, foliage = {...}, tree = {...} }
    kind = "texture",
    filter = {},        -- kind -> group title or nil (= all)
    scroll = {},        -- kind -> first visible row (0-based)
    radius = 5,
    density = 100,      -- percent
    lmb = false,
    rmb = false,
    search = "",
    lastX = nil, lastZ = nil,
    mouseX = 0, mouseY = 0,
    o = false,
    hidden = false,
    overlays = {},
    hits = {},          -- clickable rects rebuilt each draw
}
local P = MBSPanel

local R_MIN, R_MAX = 1, 25
local KINDS = { "texture", "foliage", "tree" }
local KIND_LABEL = { texture = "Textures", foliage = "Foliage", tree = "Trees" }
local SPACING = 1.3

local function isCtrl()
    return (Input.KEY_lctrl ~= nil and Input.isKeyPressed(Input.KEY_lctrl)) or (Input.KEY_rctrl ~= nil and Input.isKeyPressed(Input.KEY_rctrl))
end

local function getScreen()
    if g_gui == nil or g_gui.currentGuiName ~= "ConstructionScreen" then return nil end
    return g_gui.screenControllers ~= nil and g_gui.screenControllers[ConstructionScreen] or nil
end

----------------------------------------------------------------------------
-- data: everything that exists
----------------------------------------------------------------------------
local function tr(text)
    if text == nil then return nil end
    local ok, res = pcall(function() return g_i18n:convertText(text) end)
    return ok and res or text
end

function P:buildData()
    local data = { texture = {}, foliage = {}, tree = {} }
    local seen = {}

    -- ground textures (every layer of the loaded map)
    pcall(function()
        local names = {}
        for typeName in pairs(g_groundTypeManager.groundTypeMappings) do table.insert(names, typeName) end
        table.sort(names)
        local knownLayers = {}
        for _, typeName in ipairs(names) do
            local layer = g_groundTypeManager:getTerrainLayerByType(typeName)
            if layer ~= nil and not knownLayers[layer] then
                knownLayers[layer] = true
                table.insert(data.texture, { kind = "texture", key = "texture:" .. tostring(layer), layer = layer,
                    name = tr(g_groundTypeManager:getTerrainTitleByType(typeName)) or typeName, group = "Textures" })
            end
        end
    end)

    -- foliage + trees from the store (base game, DLC and mods)
    pcall(function()
        for _, storeItem in ipairs(g_storeManager:getItems()) do
            local b = storeItem.brush
            if b ~= nil then
                local class = g_constructionBrushTypeManager:getClassObjectByTypeName(b.type)
                local params = b.parameters
                local group = (b.tab ~= nil and tr(b.tab.title)) or "-"
                if class == ConstructionBrushFoliage and params ~= nil and params[1] ~= nil then
                    local paint = g_currentMission.foliageSystem:getFoliagePaintByName(params[1])
                    local state = tonumber(params[2])
                    if paint ~= nil and state ~= nil then
                        local key = "foliage:" .. tostring(paint.id) .. ":" .. tostring(state)
                        if not seen[key] then
                            seen[key] = true
                            table.insert(data.foliage, { kind = "foliage", key = key, foliagePaint = paint, foliageState = state,
                                name = storeItem.name or params[1], group = group, image = storeItem.imageFilename })
                        end
                    end
                elseif class == ConstructionBrushTree and params ~= nil and params[1] ~= nil then
                    local stage, variation = tonumber(params[2]), tonumber(params[3])
                    local key = "tree:" .. tostring(params[1]) .. ":" .. tostring(stage) .. ":" .. tostring(variation)
                    if stage ~= nil and not seen[key] then
                        seen[key] = true
                        table.insert(data.tree, { kind = "tree", key = key, treeType = params[1], treeStage = stage, variationIndex = variation,
                            storeItem = storeItem, name = storeItem.name or params[1], group = group, image = storeItem.imageFilename })
                    end
                end
            end
        end
    end)

    -- every tree type / stage / variation the game knows (also what the store does not list)
    pcall(function()
        for _, desc in pairs(g_treePlantManager.treeTypes) do
            if desc.stages ~= nil then
                for stage, variations in ipairs(desc.stages) do
                    for variation = 1, #variations do
                        local key = "tree:" .. tostring(desc.name) .. ":" .. stage .. ":" .. variation
                        local keyAlt = "tree:" .. tostring(desc.name) .. ":" .. stage .. ":" .. "nil"
                        if not seen[key] and not seen[keyAlt] then
                            seen[key] = true
                            table.insert(data.tree, { kind = "tree", key = key, treeType = desc.name, treeStage = stage, variationIndex = variation,
                                name = string.format("%s  s%d v%d", tostring(desc.title or desc.name), stage, variation), group = "All tree types" })
                        end
                    end
                end
            end
        end
    end)

    -- plain foliage paints that have no store entry
    pcall(function()
        local paints = g_currentMission.foliageSystem.paints or g_currentMission.foliageSystem.foliagePaints
        if paints ~= nil then
            for _, paint in pairs(paints) do
                if paint.id ~= nil and paint.name ~= nil and paint.maxValue == nil then
                    -- states unknown: skip, only store-defined states are valid
                end
            end
        end
    end)

    local treeImg = {}
    for _, e in ipairs(data.tree) do
        if e.image ~= nil and treeImg[string.lower(tostring(e.treeType))] == nil then treeImg[string.lower(tostring(e.treeType))] = e.image end
    end
    for _, e in ipairs(data.tree) do
        if e.image == nil then e.image = treeImg[string.lower(tostring(e.treeType))] end
    end

    local function byName(a, b) return tostring(a.name) < tostring(b.name) end
    table.sort(data.tree, function(a, b)
        if a.group ~= b.group then return a.group < b.group end
        return byName(a, b)
    end)
    self.data = data
    Logging.info('[MultiBrushSelect] panel data: %d textures, %d foliage, %d trees', #data.texture, #data.foliage, #data.tree)
    pcall(function()
        local tn, fn = {}, {}
        for _, d in pairs(g_treePlantManager.treeTypes) do table.insert(tn, tostring(d.name)) end
        table.sort(tn)
        for _, e in ipairs(data.foliage) do table.insert(fn, tostring(e.name)) end
        Logging.info('[MultiBrushSelect] tree types: %s', table.concat(tn, ", "))
        Logging.info('[MultiBrushSelect] foliage: %s', table.concat(fn, ", "))
    end)
end

function P:groups(kind)
    local list, seen = {}, {}
    for _, e in ipairs(self.data[kind]) do
        if not seen[e.group] then seen[e.group] = true table.insert(list, e.group) end
    end
    return list
end

function P:visibleEntries()
    local out = {}
    local f = self.filter[self.kind]
    local q = string.lower(self.search or "")
    for _, e in ipairs(self.data[self.kind]) do
        if f == nil or e.group == f then
            if q == "" or string.find(string.lower(tostring(e.name)), q, 1, true) or string.find(string.lower(tostring(e.treeType or e.group or "")), q, 1, true) then
                table.insert(out, e)
            end
        end
    end
    return out
end

function P:selectedOf(kind)
    local out = {}
    for _, e in pairs(self.selected) do
        if e.kind == kind then table.insert(out, e) end
    end
    return out
end

function P:toggle(entry)
    if self.selected[entry.key] ~= nil then
        self.selected[entry.key] = nil
        self.selectedCount = self.selectedCount - 1
    else
        self.selected[entry.key] = entry
        self.selectedCount = self.selectedCount + 1
    end
end

function P:clear()
    self.selected = {}
    self.selectedCount = 0
end

----------------------------------------------------------------------------
-- painting
----------------------------------------------------------------------------
local function sendEvent(event)
    g_client:getServerConnection():sendEvent(event)
end

local function canUse(x, y, z)
    local ok, res = pcall(function()
        if not g_currentMission.accessHandler:canFarmAccessLand(g_localPlayer.farmId, x, z, true) then return false end
        if PlacementUtil.isInsidePlacementPlaces(g_currentMission.storeSpawnPlaces, x, y, z) then return false end
        if PlacementUtil.isInsidePlacementPlaces(g_currentMission.loadSpawnPlaces, x, y, z) then return false end
        if PlacementUtil.isInsideRestrictedZone(g_currentMission.restrictedZones, x, y, z) then return false end
        return true
    end)
    return ok and res
end

local function randomInCircle(x, z, r)
    local a = math.random() * 2 * math.pi
    local d = math.sqrt(math.random()) * r
    return x + math.cos(a) * d, z + math.sin(a) * d
end

function P:applyAt(x, y, z)
    if not canUse(x, y, z) then return end
    local r = self.radius
    local dens = self.density / 100
    local shape = Landscaping.BRUSH_SHAPE.CIRCLE

    -- textures: random small patches so the textures are mixed
    local tex = self:selectedOf("texture")
    if #tex > 0 then
        local sr = math.max(0.5, math.min(1.5, r / 2))
        local n = math.min(14, math.max(1, math.ceil((r * r) / (sr * sr) * 0.5 * dens)))
        if #tex == 1 then n = 1 sr = r end
        for _ = 1, n do
            local px, pz = x, z
            if #tex > 1 then px, pz = randomInCircle(x, z, math.max(0, r - sr)) end
            local py = getTerrainHeightAtWorldPos(g_terrainNode, px, 0, pz)
            local pick = tex[math.random(1, #tex)]
            sendEvent(LandscapingSculptEvent.new(false, Landscaping.OPERATION.PAINT, px, py, pz, nil, nil, nil, nil, nil, nil, sr, 1, shape, 1, pick.layer))
        end
    end

    -- foliage: random patches, each picks one of the selected types
    local fol = self:selectedOf("foliage")
    if #fol > 0 then
        local sr = math.max(0.5, math.min(1.5, r / 2))
        local n = math.min(30, math.max(#fol, math.ceil((r * r) / (sr * sr) * 0.7 * dens)))
        for i = 1, n do
            local px, pz = randomInCircle(x, z, math.max(0, r - sr))
            local py = getTerrainHeightAtWorldPos(g_terrainNode, px, 0, pz)
            local pick = fol[(i <= #fol) and i or math.random(1, #fol)]
            sendEvent(LandscapingSculptEvent.new(false, Landscaping.OPERATION.FOLIAGE, px, py, pz, nil, nil, nil, nil, nil, nil, sr, 1, shape, 0, nil, pick.foliagePaint.id, pick.foliageState))
        end
    end

    -- trees: sparse, never touching (crown-radius aware, remembered across the whole stroke)
    local trees = self:selectedOf("tree")
    if #trees > 0 and g_treePlantManager ~= nil then
        local tx, tz = self.lastTreeX, self.lastTreeZ
        local gate = math.max(4, r)
        if tx ~= nil and (x - tx) * (x - tx) + (z - tz) * (z - tz) < gate * gate then return end
        self.lastTreeX, self.lastTreeZ = x, z
        self.treeMem = self.treeMem or {}
        local money = g_currentMission:getMoney()
        local spent = 0
        local farmId = g_localPlayer.farmId
        local area = math.pi * r * r
        local avgCr = 0
        for _, t in ipairs(trees) do
            local d = g_treePlantManager:getTreeTypeDescFromName(t.treeType)
            local n = (d ~= nil and d.stages ~= nil) and #d.stages or 1
            avgCr = avgCr + MBSPanel.crownRadius((t.treeStage or 1) / math.max(1, n))
        end
        avgCr = avgCr / #trees
        local expected = dens * area / ((2 * avgCr + 1.5) ^ 2) * 0.6
        local want = math.floor(expected)
        if math.random() < expected - want then want = want + 1 end
        local planted = 0
        for _ = 1, want * 12 do
            if planted >= want then break end
            local px, pz = randomInCircle(x, z, r)
            local pick = trees[math.random(1, #trees)]
            local desc = g_treePlantManager:getTreeTypeDescFromName(pick.treeType)
            if desc ~= nil and desc.stages ~= nil and #desc.stages > 0 then
                local stage = math.min(pick.treeStage or 1, #desc.stages)
                local variations = desc.stages[stage]
                local cr = MBSPanel.crownRadius(stage / #desc.stages)
                local free = true
                for _, m in ipairs(self.treeMem) do
                    local dx, dz = m[1] - px, m[2] - pz
                    local need = m[3] + cr + 1.0
                    if dx * dx + dz * dz < need * need then free = false break end
                end
                local py = getTerrainHeightAtWorldPos(g_terrainNode, px, 0, pz)
                if free and variations ~= nil and #variations > 0 and canUse(px, py, pz) then
                    local variation = math.min(pick.variationIndex or math.random(1, #variations), #variations)
                    local price = 0
                    if pick.storeItem ~= nil then
                        price = MathUtil.lerp(0, g_currentMission.economyManager:getBuyPrice(pick.storeItem), stage / #desc.stages)
                    end
                    if not g_treePlantManager:canPlantTree() or spent + price > money then break end
                    local ry = math.random() * 2 * math.pi
                    if g_server ~= nil then
                        local id = g_treePlantManager:plantTree(desc.index, px, py, pz, 0, ry, 0, stage, variation, false)
                        if id ~= nil then
                            self.curStroke = self.curStroke or {}
                            table.insert(self.curStroke, id)
                        end
                        g_currentMission:addMoney(-price, farmId, MoneyType.SHOP_PROPERTY_BUY, true)
                    else
                        sendEvent(TreePlantEvent.new(desc.index, px, py, pz, 0, ry, 0, stage, variation, nil, false, price, farmId))
                    end
                    spent = spent + price
                    planted = planted + 1
                    table.insert(self.treeMem, { px, pz, cr })
                    if #self.treeMem > 500 then table.remove(self.treeMem, 1) end
                end
            end
        end
    end
end

-- approximate crown radius (m) from growth fraction 0..1
function MBSPanel.crownRadius(frac)
    return 0.5 + 4.5 * math.max(0, math.min(1, frac))
end

local function removeTreeNode(node)
    if node == nil or not entityExists(node) then return false end
    local n = getNumOfChildren(node)
    for i = n - 1, 0, -1 do
        delete(getChildAt(node, i))
    end
    return true
end

function P:cleanupTrees(x, z)
    pcall(function() g_treePlantManager:cleanupDeletedTrees() end)
    if x ~= nil then
        pcall(function()
            local range = 12
            g_densityMapHeightManager:setCollisionMapAreaDirty(x - range, z - range, x + range, z + range, true)
            g_currentMission.aiSystem:setAreaDirty(x - range, x + range, z - range, z + range)
        end)
    end
end

-- removes planted trees inside the circle (only the selected tree types if any are selected)
function P:eraseTrees(x, z)
    if g_server == nil then
        if not self.warnedClientErase then
            self.warnedClientErase = true
            Logging.info('[MultiBrushSelect] tree erase works for the host / singleplayer only')
        end
        return
    end
    local td = g_treePlantManager ~= nil and g_treePlantManager.treesData or nil
    if td == nil then return end
    local types, any = {}, false
    for _, e in ipairs(self:selectedOf("tree")) do
        local d = g_treePlantManager:getTreeTypeDescFromName(e.treeType)
        if d ~= nil then types[d.index] = true any = true end
    end
    local r2 = self.radius * self.radius
    local victims = {}
    for _, list in ipairs({ td.growingTrees, td.splitTrees }) do
        for _, tree in ipairs(list) do
            local dx, dz = tree.x - x, tree.z - z
            if dx * dx + dz * dz <= r2 and (not any or types[tree.treeType]) then
                table.insert(victims, tree.node)
            end
        end
    end
    for _, node in ipairs(victims) do removeTreeNode(node) end
    if #victims > 0 then self:cleanupTrees(x, z) end
end

-- undo: removes the trees planted by the last paint stroke (host / singleplayer)
function P:undoTrees()
    local stroke = table.remove(self.strokes or {})
    if stroke == nil then return end
    local x, z
    for _, node in ipairs(stroke) do
        if entityExists(node) then
            local nx, _ny, nz = getWorldTranslation(node)
            x, z = nx, nz
            removeTreeNode(node)
        end
    end
    self:cleanupTrees(x, z)
end

-- right mouse: removes foliage (grass, weeds, flowers) inside the brush circle
function P:eraseAt(x, y, z)
    if not canUse(x, y, z) then return end
    local noBrush = TerrainDeformation ~= nil and TerrainDeformation.NO_TERRAIN_BRUSH or nil
    sendEvent(LandscapingSculptEvent.new(false, Landscaping.OPERATION.PAINT, x, y, z, nil, nil, nil, nil, nil, nil, self.radius, 1, Landscaping.BRUSH_SHAPE.CIRCLE, 0, noBrush))
    self:eraseTrees(x, z)
end

----------------------------------------------------------------------------
-- layout / drawing
----------------------------------------------------------------------------
local TEXT = 0.0135
local ROW_H = 0.036

local function panelRect(screen)
    local mb = screen ~= nil and screen.menuBox or nil
    if mb ~= nil and mb.absPosition ~= nil then
        return mb.absPosition[1], 0, mb.absSize[1], 1
    end
    return 0, 0, 0.26, 1
end

local function fit(text, size, maxW)
    text = tostring(text)
    if getTextWidth(size, text) <= maxW then return text end
    while #text > 1 and getTextWidth(size, text .. "..") > maxW do text = text:sub(1, #text - 1) end
    return text .. ".."
end

local function txt(x, y, size, text, r, g, b, bold, align)
    setTextBold(bold == true)
    setTextColor(r or 1, g or 1, b or 1, 1)
    setTextAlignment(align or RenderText.ALIGN_LEFT)
    renderText(x, y, size, text)
    setTextBold(false)
    setTextAlignment(RenderText.ALIGN_LEFT)
end

function P:addHit(x, y, w, h, fn)
    table.insert(self.hits, { x = x, y = y, w = w, h = h, fn = fn })
end

local function button(self, x, y, w, h, label, active, fn)
    if active then
        drawFilledRect(x, y, w, h, 0.62, 0.78, 0.0, 1)
        txt(x + w / 2, y + h / 2 - TEXT * 0.4, TEXT, label, 0.05, 0.06, 0.08, true, RenderText.ALIGN_CENTER)
    else
        drawFilledRect(x, y, w, h, 0.2, 0.225, 0.3, 1)
        txt(x + w / 2, y + h / 2 - TEXT * 0.4, TEXT, label, 0.9, 0.92, 0.95, false, RenderText.ALIGN_CENTER)
    end
    self:addHit(x, y, w, h, fn)
end

function P:onSearchText(text, clickedOk)
    if clickedOk == false then return end
    self.search = tostring(text or "")
    self.scroll[self.kind] = 0
end

function P:openSearch()
    local cb = function(text, clickedOk) MBSPanel:onSearchText(text, clickedOk) end
    local ok, err = pcall(function()
        g_gui:showTextInputDialog({ target = nil, callback = cb, defaultText = self.search or "", dialogPrompt = "Search", imePrompt = "Search", confirmText = "OK", maxCharacters = 40 })
    end)
    if not ok then
        Logging.info('[MultiBrushSelect] table-form text dialog failed: %s', tostring(err))
        local ok2, err2 = pcall(function()
            TextInputDialog.show(cb, nil, self.search or "", "Search", "Search", 40, "OK")
        end)
        if not ok2 then Logging.warning('[MultiBrushSelect] search dialog unavailable: %s', tostring(err2)) end
    end
end

function P:getOverlay(path)
    if path == nil then return nil end
    local o = self.overlays[path]
    if o == nil then
        local ok, id = pcall(createImageOverlay, path)
        o = ok and id or false
        self.overlays[path] = o
    end
    return o or nil
end

local function hashColor(str)
    local h = 7
    for i = 1, #str do h = (h * 31 + str:byte(i)) % 997 end
    local r = 0.25 + ((h * 13) % 60) / 100
    local g = 0.25 + ((h * 29) % 60) / 100
    local b = 0.25 + ((h * 47) % 60) / 100
    return r, g, b
end

function P:drawIcon(e, x, y, w, h)
    local ov = self:getOverlay(e.image)
    if ov ~= nil then
        renderOverlay(ov, x, y, w, h)
        return
    end
    if e.kind == "texture" and e.layer ~= nil and not self.noLayerEl and TerrainLayerElement ~= nil then
        local ok, err = pcall(function()
            if self.layerEl == nil then
                self.layerEl = TerrainLayerElement.new()
                local names, seen, c = {}, {}, TerrainLayerElement
                local depth = 0
                while type(c) == "table" and not seen[c] and depth < 6 do
                    seen[c] = true
                    for k, v in pairs(c) do
                        if type(v) == "function" and (tostring(k):find("ize") or tostring(k):find("osition") or tostring(k):find("raw") or tostring(k):find("Layer")) then
                            table.insert(names, tostring(k))
                        end
                    end
                    local mt = getmetatable(c)
                    c = mt ~= nil and (mt.__index or mt) or nil
                    depth = depth + 1
                end
                table.sort(names)
                Logging.info('[MultiBrushSelect] TerrainLayerElement methods: %s', table.concat(names, ","))
            end
            local el = self.layerEl
            if el.setSize == nil then error("no setSize") end
            el:setTerrainLayer(g_terrainNode, e.layer)
            el:setSize(w, h)
            if el.setAbsolutePosition ~= nil then
                el:setAbsolutePosition(x, y)
            else
                el.absPosition = { x, y }
            end
            el.absSize = { w, h }
            el:draw()
        end)
        if ok then return end
        self.noLayerEl = true
        Logging.warning('[MultiBrushSelect] terrain layer icon not available (%s), using swatches', tostring(err))
    end
    if e.kind == "tree" then
        drawFilledRect(x, y, w, h, 0.16, 0.2, 0.17, 1)
        drawFilledRect(x + w * 0.45, y + h * 0.05, w * 0.1, h * 0.3, 0.42, 0.3, 0.18, 1)
        drawFilledRect(x + w * 0.2, y + h * 0.3, w * 0.6, h * 0.25, 0.2, 0.5, 0.2, 1)
        drawFilledRect(x + w * 0.3, y + h * 0.52, w * 0.4, h * 0.22, 0.24, 0.58, 0.24, 1)
        drawFilledRect(x + w * 0.4, y + h * 0.72, w * 0.2, h * 0.18, 0.3, 0.66, 0.3, 1)
        return
    end
    local r, g, b = hashColor(tostring(e.name))
    drawFilledRect(x, y, w, h, r, g, b, 1)
    txt(x + w / 2, y + h / 2 - TEXT * 0.4, TEXT, string.upper(string.sub(tostring(e.name), 1, 1)), 1, 1, 1, true, RenderText.ALIGN_CENTER)
end

function P:drawPanel(screen)
    self.hits = {}
    local px, py, pw, ph = panelRect(screen)
    local aspect = g_screenWidth / g_screenHeight
    drawFilledRect(px, py, pw, ph, 0.075, 0.085, 0.125, 0.98)
    drawFilledRect(px + pw - 0.001, py, 0.001, ph, 0.62, 0.78, 0.0, 1)
    local pad = 0.008
    local x0, w = px + pad, pw - 2 * pad
    local y = py + ph - 0.03

    txt(x0, y, TEXT * 1.35, "MULTI BRUSH", 0.62, 0.78, 0.0, true)
    txt(px + pw - pad, y, TEXT * 0.85, "Ctrl+O to close", 0.55, 0.58, 0.65, false, RenderText.ALIGN_RIGHT)
    drawFilledRect(x0, y - 0.012, w, 0.0015, 0.62, 0.78, 0.0, 0.8)
    y = y - 0.04

    -- kind tabs
    local tw = w / #KINDS
    for i, kind in ipairs(KINDS) do
        local count = #self:selectedOf(kind)
        local label = KIND_LABEL[kind] .. (count > 0 and (" (" .. count .. ")") or "")
        button(self, x0 + (i - 1) * tw, y, tw - 0.002, 0.032, label, self.kind == kind, function() self.kind = kind end)
    end
    y = y - 0.036

    -- search box
    local hasQuery = (self.search or "") ~= ""
    local fieldW = hasQuery and (w - 0.034) or w
    drawFilledRect(x0, y, fieldW, 0.03, 0.04, 0.045, 0.07, 1)
    drawFilledRect(x0, y, fieldW, 0.0012, 0.62, 0.78, 0.0, hasQuery and 1 or 0.4)
    if hasQuery then
        txt(x0 + 0.006, y + 0.008, TEXT, fit(self.search, TEXT, fieldW - 0.012), 1, 1, 1)
    else
        txt(x0 + 0.006, y + 0.008, TEXT, "Search... (click to type)", 0.5, 0.53, 0.6)
    end
    self:addHit(x0, y, fieldW, 0.03, function() self:openSearch() end)
    if hasQuery then
        button(self, x0 + w - 0.03, y, 0.03, 0.03, "x", false, function() self.search = "" self.scroll[self.kind] = 0 end)
    end
    y = y - 0.036

    -- group chips
    local groups = self:groups(self.kind)
    if #groups > 1 then
        local chips = { nil }
        for _, g in ipairs(groups) do table.insert(chips, g) end
        local perRow = 3
        local cw = w / perRow
        local rows = math.ceil((#chips + 1) / perRow)
        local list = { false }
        for _, g in ipairs(groups) do table.insert(list, g) end
        for i, g in ipairs(list) do
            local col = (i - 1) % perRow
            local row = math.floor((i - 1) / perRow)
            local cx, cy = x0 + col * cw, y - row * 0.03
            local label = g == false and "All" or fit(g, TEXT * 0.9, cw - 0.012)
            local active = (g == false and self.filter[self.kind] == nil) or (g ~= false and self.filter[self.kind] == g)
            button(self, cx, cy, cw - 0.002, 0.027, label, active, function()
                self.filter[self.kind] = (g ~= false) and g or nil
                self.scroll[self.kind] = 0
            end)
        end
        y = y - rows * 0.03 - 0.004
    end

    -- list
    local footer = 0.20
    local listTop = y
    local listBottom = py + footer
    local rowsVisible = math.max(1, math.floor((listTop - listBottom) / ROW_H))
    local entries = self:visibleEntries()
    local maxScroll = math.max(0, #entries - rowsVisible)
    local scroll = math.max(0, math.min(self.scroll[self.kind] or 0, maxScroll))
    self.scroll[self.kind] = scroll
    self.listRect = { x = px, y = listBottom, w = pw, h = listTop - listBottom, rows = rowsVisible, max = maxScroll }

    local iconH = ROW_H * 0.88
    local iconW = iconH / aspect
    for i = 1, rowsVisible do
        local e = entries[scroll + i]
        if e == nil then break end
        local ry = listTop - i * ROW_H
        local sel = self.selected[e.key] ~= nil
        if sel then
            drawFilledRect(x0, ry, w - 0.008, ROW_H - 0.002, 0.62, 0.78, 0.0, 0.22)
            drawFilledRect(x0, ry, w - 0.008, 0.0012, 0.62, 0.78, 0.0, 1)
            drawFilledRect(x0, ry + ROW_H - 0.0032, w - 0.008, 0.0012, 0.62, 0.78, 0.0, 1)
            drawFilledRect(x0, ry, 0.0012, ROW_H - 0.002, 0.62, 0.78, 0.0, 1)
            drawFilledRect(x0 + w - 0.0092, ry, 0.0012, ROW_H - 0.002, 0.62, 0.78, 0.0, 1)
        else
            drawFilledRect(x0, ry, w - 0.008, ROW_H - 0.002, 0.13, 0.145, 0.2, 1)
        end
        local tx = x0 + 0.004
        self:drawIcon(e, x0 + 0.002, ry + 0.001, iconW, iconH)
        tx = x0 + iconW + 0.007
        txt(tx, ry + ROW_H * 0.52, TEXT, fit(e.name, TEXT, x0 + w - 0.012 - tx), 1, 1, 1, sel)
        if e.kind == "tree" then
            txt(tx, ry + ROW_H * 0.12, TEXT * 0.75, fit(tostring(e.treeType) .. "  stage " .. tostring(e.treeStage), TEXT * 0.75, x0 + w - 0.012 - tx), 0.55, 0.58, 0.65)
        elseif e.group ~= nil then
            txt(tx, ry + ROW_H * 0.12, TEXT * 0.75, fit(e.group, TEXT * 0.75, x0 + w - 0.012 - tx), 0.55, 0.58, 0.65)
        end
        self:addHit(x0, ry, w - 0.008, ROW_H - 0.002, function() self:toggle(e) end)
    end
    if maxScroll > 0 then
        local barH = (listTop - listBottom) * rowsVisible / #entries
        local barY = listTop - barH - (listTop - listBottom - barH) * (scroll / maxScroll)
        drawFilledRect(px + pw - 0.006, barY, 0.003, barH, 0.62, 0.78, 0.0, 0.9)
    end
    if #entries == 0 then
        txt(x0 + 0.01, listTop - 0.05, TEXT, "(nothing in this category)", 0.55, 0.58, 0.65)
    end

    -- footer
    local fy = py + footer - 0.03
    drawFilledRect(px, py, pw, footer, 0.1, 0.11, 0.16, 1)
    txt(x0, fy, TEXT, string.format("Selected: %d textures, %d foliage, %d trees",
        #self:selectedOf("texture"), #self:selectedOf("foliage"), #self:selectedOf("tree")), 1, 1, 1)
    button(self, x0, fy - 0.036, w / 2 - 0.002, 0.03, "Clear selection", false, function() self:clear() end)
    button(self, x0 + w / 2 + 0.002, fy - 0.036, w / 2 - 0.002, 0.03, "Undo trees (Ctrl+Z)", false, function() self:undoTrees() end)

    local function stepper(yy, label, valueText, onMinus, onPlus)
        txt(x0, yy + 0.008, TEXT, label, 0.8, 0.8, 0.8)
        local bx = x0 + w * 0.45
        button(self, bx, yy, 0.026, 0.03, "-", false, onMinus)
        txt(bx + 0.026 + (w * 0.55 - 0.052) / 2, yy + 0.008, TEXT, valueText, 1, 1, 1, true, RenderText.ALIGN_CENTER)
        button(self, x0 + w - 0.026, yy, 0.026, 0.03, "+", false, onPlus)
    end
    stepper(fy - 0.076, "Radius", string.format("%d m", self.radius),
        function() self.radius = math.max(R_MIN, self.radius - 1) end,
        function() self.radius = math.min(R_MAX, self.radius + 1) end)
    stepper(fy - 0.114, "Density", string.format("%d%%", self.density),
        function() self.density = math.max(10, self.density - 10) end,
        function() self.density = math.min(300, self.density + 10) end)
    txt(x0, py + 0.012, TEXT * 0.8, "LMB paint  |  RMB erase foliage + trees  |  Ctrl+Z undo trees", 0.55, 0.58, 0.65)
end

function P:drawMarker(screen)
    if screen == nil or screen.cursor == nil or self.listRect == nil then return end
    local ok, x, y, z = pcall(function() return screen.cursor:getHitTerrainPosition() end)
    if not ok or x == nil or self:overPanel(self.mouseX, self.mouseY) then return end
    local n, r = 28, self.radius
    local prevX, prevY, prevZ
    for i = 0, n do
        local a = i / n * 2 * math.pi
        local cx, cz = x + math.cos(a) * r, z + math.sin(a) * r
        local cy = getTerrainHeightAtWorldPos(g_terrainNode, cx, 0, cz) + 0.15
        if prevX ~= nil then
            drawDebugLine(prevX, prevY, prevZ, self.rmb and 1 or 0.62, self.rmb and 0.2 or 0.78, 0.0, cx, cy, cz, self.rmb and 1 or 0.62, self.rmb and 0.2 or 0.78, 0.0, false)
        end
        prevX, prevY, prevZ = cx, cy, cz
    end
end

function P:overPanel(mx, my)
    local lr = self.panelBounds
    if lr == nil then return false end
    return mx >= lr.x and mx <= lr.x + lr.w and my >= lr.y and my <= lr.y + lr.h
end

----------------------------------------------------------------------------
-- screen hooks
----------------------------------------------------------------------------
function P:setDefaultMenuVisible(screen, visible)
    for _, name in ipairs({ "menuBox", "categoryContainer" }) do
        local el = screen[name]
        if el ~= nil and el.setVisible ~= nil then pcall(el.setVisible, el, visible) end
    end
end

function P:handleMouse(posX, posY, isDown, isUp, button)
    self.mouseX, self.mouseY = posX, posY
    if not self.active or getScreen() == nil then return end
    local left = Input.MOUSE_BUTTON_LEFT or 1
    if isDown and button == left then
        if self:overPanel(posX, posY) then
            for _, h in ipairs(self.hits) do
                if posX >= h.x and posX <= h.x + h.w and posY >= h.y and posY <= h.y + h.h then
                    h.fn()
                    break
                end
            end
        else
            self.lmb = true
            self.lastX = nil
            self.lastTreeX = nil
            self.treeMem = {}
        end
    elseif isDown and button == (Input.MOUSE_BUTTON_RIGHT or 3) and not self:overPanel(posX, posY) then
        self.rmb = true
        self.lastEraseX = nil
    elseif isUp and button == (Input.MOUSE_BUTTON_RIGHT or 3) then
        self.rmb = false
        self.lastEraseX = nil
    elseif isUp and button == left then
        self.lmb = false
        self.lastX = nil
        if self.curStroke ~= nil and #self.curStroke > 0 then
            self.strokes = self.strokes or {}
            table.insert(self.strokes, self.curStroke)
            if #self.strokes > 40 then table.remove(self.strokes, 1) end
        end
        self.curStroke = nil
    elseif isDown and self:overPanel(posX, posY) then
        local up, down = Input.MOUSE_BUTTON_WHEEL_UP, Input.MOUSE_BUTTON_WHEEL_DOWN
        local step = nil
        if up ~= nil and button == up then step = -3 elseif down ~= nil and button == down then step = 3 end
        if step ~= nil then
            self.scroll[self.kind] = math.max(0, (self.scroll[self.kind] or 0) + step)
        end
    end
end

function P:trigger(src)
    if self.lastTrigger ~= nil and g_time - self.lastTrigger < 400 then return end
    self.lastTrigger = g_time
    local screen = getScreen()
    Logging.info('[MultiBrushSelect] Ctrl+O (%s) screen=%s gui=%s', src, tostring(screen ~= nil), tostring(g_gui ~= nil and g_gui.currentGuiName))
    if screen ~= nil then
        self.active = not self.active
        if self.data == nil and self.active then pcall(self.buildData, self) end
    elseif g_currentMission ~= nil and not g_gui:getIsGuiVisible() and g_localPlayer ~= nil then
        if self.data == nil then
            local ok, err = pcall(self.buildData, self)
            if not ok then Logging.warning('[MultiBrushSelect] panel data failed: %s', tostring(err)) end
        end
        self.active = true
        self.openAt = g_time
        local ok, err = pcall(g_gui.showGui, g_gui, "ConstructionScreen")
        Logging.info('[MultiBrushSelect] open construction screen: %s %s', tostring(ok), tostring(err))
        if not ok then self.active = false end
    end
end

function P:keyEvent(unicode, sym, modifier, isDown)
    if isDown and Input.KEY_o ~= nil and sym == Input.KEY_o and isCtrl() then
        self:trigger("keyEvent")
    end
end

function P:update(dt)
    if g_dedicatedServer ~= nil or g_gui == nil then return end
    local screen = getScreen()

    -- Ctrl+O (polled; also see keyEvent below)
    local oDown = Input.KEY_o ~= nil and Input.isKeyPressed(Input.KEY_o)
    if oDown and not self.o and isCtrl() then
        self:trigger("poll")
    end
    self.o = oDown
    local zDown = Input.KEY_z ~= nil and Input.isKeyPressed(Input.KEY_z)
    if zDown and not self.z and isCtrl() and self.active and getScreen() ~= nil then
        pcall(self.undoTrees, self)
    end
    self.z = zDown
    screen = getScreen()

    if screen == nil then
        if self.hidden then
            local sc = g_gui.screenControllers ~= nil and g_gui.screenControllers[ConstructionScreen] or nil
            if sc ~= nil then self:setDefaultMenuVisible(sc, true) end
        end
        self.hidden = false
        self.lmb = false
        if not g_gui:getIsGuiVisible() and g_time - (self.openAt or 0) > 1500 then self.active = false end
        return
    end

    if self.active then
        if self.data == nil then pcall(self.buildData, self) end
        if not self.hidden then
            self:setDefaultMenuVisible(screen, false)
            self.hidden = true
        end
        if self.lmb and screen.cursor ~= nil then
            local ok, x, y, z = pcall(function() return screen.cursor:getHitTerrainPosition() end)
            if ok and x ~= nil then
                local step = math.max(0.5, self.radius * 0.5)
                local moved = self.lastX == nil
                if not moved then
                    local dx, dz = x - self.lastX, z - self.lastZ
                    moved = dx * dx + dz * dz >= step * step
                end
                if moved then
                    self.lastX, self.lastZ = x, z
                    local ok2, err = pcall(self.applyAt, self, x, y, z)
                    if not ok2 then Logging.warning('[MultiBrushSelect] panel apply failed: %s', tostring(err)) end
                end
            end
        end
        if self.rmb and screen.cursor ~= nil then
            local ok, x, y, z = pcall(function() return screen.cursor:getHitTerrainPosition() end)
            if ok and x ~= nil then
                local step = math.max(0.5, self.radius * 0.4)
                local moved = self.lastEraseX == nil
                if not moved then
                    local dx, dz = x - self.lastEraseX, z - self.lastEraseZ
                    moved = dx * dx + dz * dz >= step * step
                end
                if moved then
                    self.lastEraseX, self.lastEraseZ = x, z
                    local ok2, err = pcall(self.eraseAt, self, x, y, z)
                    if not ok2 then Logging.warning('[MultiBrushSelect] erase failed: %s', tostring(err)) end
                end
            end
        end
    elseif self.hidden then
        self:setDefaultMenuVisible(screen, true)
        self.hidden = false
        self.lmb = false
        self.rmb = false
    end
end

function P:drawOverlay()
    if g_dedicatedServer ~= nil or not self.active or self.data == nil then return end
    local screen = getScreen()
    if screen == nil then return end
    local px, py, pw, ph = panelRect(screen)
    self.panelBounds = { x = px, y = py, w = pw, h = ph }
    local ok, err = pcall(self.drawPanel, self, screen)
    if not ok then
        if not self.drawFailed then Logging.warning('[MultiBrushSelect] panel draw failed: %s', tostring(err)) end
        self.drawFailed = true
    end
    pcall(self.drawMarker, self, screen)
end

if ConstructionScreen ~= nil then
    ConstructionScreen.mouseEvent = Utils.appendedFunction(ConstructionScreen.mouseEvent, function(self, posX, posY, isDown, isUp, button)
        local ok, err = pcall(MBSPanel.handleMouse, MBSPanel, posX, posY, isDown, isUp, button)
        if not ok then Logging.warning('[MultiBrushSelect] panel mouse failed: %s', tostring(err)) end
    end)

    ConstructionScreen.draw = Utils.appendedFunction(ConstructionScreen.draw, function(self)
        local ok, err = pcall(MBSPanel.drawOverlay, MBSPanel)
        if not ok then Logging.warning('[MultiBrushSelect] panel overlay failed: %s', tostring(err)) end
    end)
end

addModEventListener(MBSPanel)
