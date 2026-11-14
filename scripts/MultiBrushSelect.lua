Logging.info('[MultiBrushSelect] MultiBrushSelect.lua loaded')
-- Construction menu: hold CTRL and click several items (ground textures, foliage, trees) to select them.
--  * several textures / several foliage types are mixed randomly while you paint
--  * textures + foliage + trees can be combined: every paint stroke also applies the other selected kinds
--  * trees: with 2+ trees selected the brush becomes a seed brush: click / drag scatters random selected trees
--    inside the brush circle (PageUp / PageDown = radius); with 1 tree it plants one per click

MultiBrushSelect = {
    selection = {},     -- entries: { kind = "texture"|"foliage"|"tree", key, name, ... }
    lastBrush = nil,
    ctrlTimer = 0,
    wasInConstruction = false,
}
local MBS = MultiBrushSelect

local CTRL_GRACE_MS = 400
local TREE_CHANCE_PER_STEP = 0.025   -- chance to also plant a tree on every paint/foliage step
local TREE_AROUND_RADIUS = 1.5       -- texture/foliage patch painted around a single planted tree
local SCATTER_DENSITY = 0.012         -- trees per m2 in scatter ("seed") mode
local SCATTER_MAX_PER_STEP = 40
local SCATTER_MIN_SPACING = 7
local SCATTER_RADIUS_MIN, SCATTER_RADIUS_MAX = 1, 25
MultiBrushSelect.scatterRadius = 5
local KIND_LABEL = { texture = "Textures", foliage = "Foliage", tree = "Trees" }
local KIND_ORDER = { "texture", "foliage", "tree" }

local function isCtrlDown()
    local l = Input.KEY_lctrl ~= nil and Input.isKeyPressed(Input.KEY_lctrl)
    local r = Input.KEY_rctrl ~= nil and Input.isKeyPressed(Input.KEY_rctrl)
    return l or r
end

local function brushKind(brush)
    if brush == nil then return nil end
    if brush.setTree ~= nil and brush.treeType ~= nil then return "tree" end
    if brush.setFoliageType ~= nil and brush.foliagePaint ~= nil then return "foliage" end
    if brush.setGroundType ~= nil and brush.terrainLayer ~= nil then return "texture" end
    return nil
end

local function itemNameFor(screen, brush)
    if brush.uniqueIndex ~= nil and screen.items ~= nil then
        for _, category in pairs(screen.items) do
            for _, tab in pairs(category) do
                for _, item in ipairs(tab) do
                    if item.uniqueIndex == brush.uniqueIndex then return item.name end
                end
            end
        end
    end
    return nil
end

local function makeEntry(kind, brush, name)
    local e = MBS.makeEntryBase(kind, brush, name)
    e.uniqueIndex = brush.uniqueIndex
    return e
end

function MBS.makeEntryBase(kind, brush, name)
    if kind == "tree" then
        return { kind = kind, key = "tree:" .. tostring(brush.treeType) .. ":" .. tostring(brush.treeStage) .. ":" .. tostring(brush.variationIndex), treeType = brush.treeType, treeStage = brush.treeStage, variationIndex = brush.variationIndex, storeItem = brush.storeItem, name = name or tostring(brush.treeType) }
    elseif kind == "foliage" then
        return { kind = kind, key = "foliage:" .. tostring(brush.foliagePaint.id) .. ":" .. tostring(brush.foliageState), foliagePaint = brush.foliagePaint, foliageState = brush.foliageState, name = name or "Foliage" }
    end
    return { kind = kind, key = "texture:" .. tostring(brush.terrainLayer), layer = brush.terrainLayer, name = name or "Texture" }
end

function MBS:entriesOf(kind)
    local list = {}
    for _, entry in ipairs(self.selection) do
        if entry.kind == kind then table.insert(list, entry) end
    end
    return list
end

function MBS:pick(kind)
    local list = self:entriesOf(kind)
    if #list == 0 then return nil end
    return list[math.random(1, #list)]
end

function MBS:onBrushSelected(entry, ctrl)
    if not ctrl then
        self.selection = { entry }
        return
    end
    for i, existing in ipairs(self.selection) do
        if existing.key == entry.key then
            if #self.selection > 1 then table.remove(self.selection, i) end
            return
        end
    end
    table.insert(self.selection, entry)
end

----------------------------------------------------------------------------
-- update / draw
----------------------------------------------------------------------------
function MBS:update(dt)
    if g_dedicatedServer ~= nil or g_gui == nil or ConstructionScreen == nil then return end

    if isCtrlDown() then
        self.ctrlTimer = CTRL_GRACE_MS
    elseif self.ctrlTimer > 0 then
        self.ctrlTimer = self.ctrlTimer - dt
    end

    if g_gui.currentGuiName ~= "ConstructionScreen" then
        if self.wasInConstruction then
            self.selection = {}
            self.lastBrush = nil
            self.wasInConstruction = false
        end
        return
    end
    self.wasInConstruction = true

    self:updateRadiusKeys(dt)

    local screen = g_gui.screenControllers ~= nil and g_gui.screenControllers[ConstructionScreen] or nil
    if screen == nil then return end
    local brush = screen.brush
    if brush ~= self.lastBrush then
        self.lastBrush = brush
        local kind = brushKind(brush)
        if kind ~= nil then
            local ok, err = pcall(function()
                self:onBrushSelected(makeEntry(kind, brush, itemNameFor(screen, brush)), self.ctrlTimer > 0)
            end)
            if not ok then Logging.warning('[MultiBrushSelect] select failed: %s', tostring(err)) end
            Logging.info('[MultiBrushSelect] selection size %d', #self.selection)
        end
    end
end

local RADIUS_UP_KEYS, RADIUS_DOWN_KEYS = {}, {}
for _, name in ipairs({ "KEY_pageup", "KEY_KP_add", "KEY_plus" }) do
    if Input[name] ~= nil then table.insert(RADIUS_UP_KEYS, Input[name]) end
end
for _, name in ipairs({ "KEY_pagedown", "KEY_KP_subtract", "KEY_minus" }) do
    if Input[name] ~= nil then table.insert(RADIUS_DOWN_KEYS, Input[name]) end
end
Logging.info('[MultiBrushSelect] radius keys up=%d down=%d', #RADIUS_UP_KEYS, #RADIUS_DOWN_KEYS)

local function anyKey(list)
    for _, key in ipairs(list) do
        if Input.isKeyPressed(key) then return true end
    end
    return false
end

MultiBrushSelect.radiusTimer = 0
function MBS:updateRadiusKeys(dt)
    if self.radiusTimer > 0 then self.radiusTimer = self.radiusTimer - dt end
    if self.radiusTimer > 0 then return end
    local delta = 0
    if anyKey(RADIUS_UP_KEYS) then delta = 1 elseif anyKey(RADIUS_DOWN_KEYS) then delta = -1 end
    if delta ~= 0 then
        self.scatterRadius = math.max(SCATTER_RADIUS_MIN, math.min(SCATTER_RADIUS_MAX, self.scatterRadius + delta))
        self.radiusTimer = 120
    end
end

local function shadowed(x, y, size, text, r, g, b, bold)
    setTextBold(bold)
    setTextColor(0, 0, 0, 1)
    renderText(x + 0.0007, y - 0.0012, size, text)
    setTextColor(r, g, b, 1)
    renderText(x, y, size, text)
    setTextBold(false)
end

local function drawFrame(x, y, w, h, t)
    drawFilledRect(x, y, w, h, 1, 0.6, 0, 0.14)
    drawFilledRect(x, y + h - t, w, t, 1, 0.6, 0, 1)
    drawFilledRect(x, y, w, t, 1, 0.6, 0, 1)
    drawFilledRect(x, y, t * 0.6, h, 1, 0.6, 0, 1)
    drawFilledRect(x + w - t * 0.6, y, t * 0.6, h, 1, 0.6, 0, 1)
end

function MBS:drawListHighlights()
    local screen = g_gui.screenControllers ~= nil and g_gui.screenControllers[ConstructionScreen] or nil
    if screen == nil or screen.itemList == nil or screen.items == nil or screen.currentCategory == nil or screen.currentTab == nil then return end
    local items = screen.items[screen.currentCategory] ~= nil and screen.items[screen.currentCategory][screen.currentTab] or nil
    local section = screen.itemList.sections ~= nil and screen.itemList.sections[1] or nil
    if items == nil or section == nil or section.cells == nil then return end
    local selected = {}
    for _, entry in ipairs(self.selection) do
        if entry.uniqueIndex ~= nil then selected[entry.uniqueIndex] = true end
    end
    for index, cell in pairs(section.cells) do
        local item = items[index]
        if item ~= nil and selected[item.uniqueIndex] and cell.absPosition ~= nil and cell.absSize ~= nil then
            drawFrame(cell.absPosition[1], cell.absPosition[2], cell.absSize[1], cell.absSize[2], 0.003)
        end
    end
end

function MBS:draw()
    if g_dedicatedServer ~= nil or g_gui == nil or g_gui.currentGuiName ~= "ConstructionScreen" then return end
    if #self.selection > 0 then pcall(self.drawListHighlights, self) end
    if brushKind(self.lastBrush) == nil or #self.selection == 0 then return end
    setTextAlignment(RenderText.ALIGN_CENTER)
    local y = 0.94
    for _, kind in ipairs(KIND_ORDER) do
        local names = {}
        for _, entry in ipairs(self:entriesOf(kind)) do table.insert(names, entry.name) end
        if #names > 0 then
            shadowed(0.6, y, 0.017, string.format("%s (%d): %s", KIND_LABEL[kind], #names, table.concat(names, ", ")), 0.55, 0.9, 0.35, true)
            y = y - 0.024
        end
    end
    if #self:entriesOf("tree") >= 2 and brushKind(self.lastBrush) == "tree" then
        shadowed(0.6, y, 0.015, string.format("Seed mode: click / drag to scatter trees. Radius %d m (PageUp / PageDown)", self.scatterRadius), 1, 0.85, 0, true)
        y = y - 0.022
    end
    shadowed(0.6, y, 0.013, "CTRL + click: add / remove from selection", 1, 1, 1, false)
    setTextAlignment(RenderText.ALIGN_LEFT)
end

----------------------------------------------------------------------------
-- extras: apply the other selected kinds at a position
----------------------------------------------------------------------------
local function sendEvent(event)
    g_client:getServerConnection():sendEvent(event)
end

function MBS.plantTreeAround(brush, x, z, radius)
    local pick = MBS:pick("tree")
    if pick == nil or g_treePlantManager == nil or not g_treePlantManager:canPlantTree() then return end
    local desc = g_treePlantManager:getTreeTypeDescFromName(pick.treeType)
    if desc == nil or desc.stages == nil or #desc.stages == 0 then return end
    local stage = math.min(pick.treeStage or 1, #desc.stages)
    local variations = desc.stages[stage]
    if variations == nil or #variations == 0 then return end
    local variation = math.min(pick.variationIndex or math.random(1, #variations), #variations)
    local px = x + (math.random() * 2 - 1) * radius
    local pz = z + (math.random() * 2 - 1) * radius
    local py = getTerrainHeightAtWorldPos(g_terrainNode, px, 0, pz)
    if brush.verifyAccess ~= nil and brush:verifyAccess(px, py, pz) ~= nil then return end
    local price = 0
    if pick.storeItem ~= nil then
        price = MathUtil.lerp(0, g_currentMission.economyManager:getBuyPrice(pick.storeItem), stage / #desc.stages)
    end
    if price > g_currentMission:getMoney() then return end
    local ry = math.random() * 2 * math.pi
    if g_server ~= nil then
        g_treePlantManager:plantTree(desc.index, px, py, pz, 0, ry, 0, stage, variation, false)
        g_currentMission:addMoney(-price, g_localPlayer.farmId, MoneyType.SHOP_PROPERTY_BUY, true)
    else
        sendEvent(TreePlantEvent.new(desc.index, px, py, pz, 0, ry, 0, stage, variation, nil, false, price, g_localPlayer.farmId))
    end
end

-- activeKind: kind of the brush that just acted (it already did its own work)
function MBS.applyExtras(activeKind, brush, x, y, z, radius, shape)
    if x == nil or #MBS.selection < 2 then return end
    do
        -- every selected foliage type is applied (the brush's own one is already done by the brush itself)
        local ownKey = nil
        if activeKind == "foliage" and brush.foliagePaint ~= nil then
            ownKey = "foliage:" .. tostring(brush.foliagePaint.id) .. ":" .. tostring(brush.foliageState)
        end
        for _, entry in ipairs(MBS:entriesOf("foliage")) do
            if entry.key ~= ownKey then
                sendEvent(LandscapingSculptEvent.new(false, Landscaping.OPERATION.FOLIAGE, x, y, z, nil, nil, nil, nil, nil, nil, radius, 1, shape, 0, nil, entry.foliagePaint.id, entry.foliageState))
            end
        end
    end
    if activeKind ~= "texture" then
        local pick = MBS:pick("texture")
        if pick ~= nil then
            sendEvent(LandscapingSculptEvent.new(false, Landscaping.OPERATION.PAINT, x, y, z, nil, nil, nil, nil, nil, nil, radius, 1, shape, 1, pick.layer))
        end
    end
    if activeKind ~= "tree" and math.random() < TREE_CHANCE_PER_STEP then
        MBS.plantTreeAround(brush, x, z, radius)
    end
end

local function stepExtras(kind, brush)
    local x, y, z = brush.cursor:getHitTerrainPosition()
    MBS.applyExtras(kind, brush, x, y, z, brush.brushRadius or 1, brush.brushShape)
end

----------------------------------------------------------------------------
-- brush hooks
----------------------------------------------------------------------------
if ConstructionBrushPaint ~= nil then
    ConstructionBrushPaint.onButtonPrimary = Utils.overwrittenFunction(ConstructionBrushPaint.onButtonPrimary, function(self, superFunc, isDown, isDrag, isUp)
        if not isUp then
            local pick = MBS:pick("texture")
            if pick ~= nil and #MBS:entriesOf("texture") > 1 then self.terrainLayer = pick.layer end
        end
        local bx, bz = self.lastX, self.lastZ
        superFunc(self, isDown, isDrag, isUp)
        if not isUp and self.lastX ~= nil and (self.lastX ~= bx or self.lastZ ~= bz) then
            local ok, err = pcall(stepExtras, "texture", self)
            if not ok then Logging.warning('[MultiBrushSelect] extras failed: %s', tostring(err)) end
        end
    end)
end

if ConstructionBrushFoliage ~= nil then
    ConstructionBrushFoliage.onButtonPrimary = Utils.overwrittenFunction(ConstructionBrushFoliage.onButtonPrimary, function(self, superFunc, isDown, isDrag, isUp)
        local bx, bz = self.lastX, self.lastZ
        superFunc(self, isDown, isDrag, isUp)
        if not isUp and self.lastX ~= nil and (self.lastX ~= bx or self.lastZ ~= bz) then
            local ok, err = pcall(stepExtras, "foliage", self)
            if not ok then Logging.warning('[MultiBrushSelect] extras failed: %s', tostring(err)) end
        end
    end)
end

local function treeCount()
    return #MBS:entriesOf("tree")
end

-- Seed mode: scatter several randomly chosen trees from the selection inside the brush circle.
function MBS.scatterTrees(brush, cx, cy, cz)
    local trees = MBS:entriesOf("tree")
    if #trees == 0 or g_treePlantManager == nil then return 0 end
    local radius = MBS.scatterRadius
    local wanted = math.min(SCATTER_MAX_PER_STEP, math.max(1, math.floor(radius * radius * math.pi * SCATTER_DENSITY + 0.5)))
    local placed, planted, spent = {}, 0, 0
    local money = g_currentMission:getMoney()
    local farmId = g_localPlayer.farmId
    for _ = 1, wanted * 3 do
        if planted >= wanted then break end
        local angle = math.random() * 2 * math.pi
        local dist = radius * math.sqrt(math.random())
        local px, pz = cx + math.cos(angle) * dist, cz + math.sin(angle) * dist
        local free = true
        for _, p in ipairs(placed) do
            local dx, dz = p[1] - px, p[2] - pz
            if dx * dx + dz * dz < SCATTER_MIN_SPACING * SCATTER_MIN_SPACING then free = false break end
        end
        if free then
            local py = getTerrainHeightAtWorldPos(g_terrainNode, px, 0, pz)
            if brush:verifyAccess(px, py, pz) == nil then
                local pick = trees[math.random(1, #trees)]
                local desc = g_treePlantManager:getTreeTypeDescFromName(pick.treeType)
                if desc ~= nil and desc.stages ~= nil and #desc.stages > 0 then
                    local stage = math.min(pick.treeStage or brush.treeStage or 1, #desc.stages)
                    local variations = desc.stages[stage]
                    if variations ~= nil and #variations > 0 then
                        local price = 0
                        if pick.storeItem ~= nil then
                            price = MathUtil.lerp(0, g_currentMission.economyManager:getBuyPrice(pick.storeItem), stage / #desc.stages)
                        end
                        if not g_treePlantManager:canPlantTree() or spent + price > money then break end
                        local variation = math.min(pick.variationIndex or math.random(1, #variations), #variations)
                        local ry = math.random() * 2 * math.pi
                        if g_server ~= nil then
                            g_treePlantManager:plantTree(desc.index, px, py, pz, 0, ry, 0, stage, variation, false)
                            g_currentMission:addMoney(-price, farmId, MoneyType.SHOP_PROPERTY_BUY, true)
                        else
                            sendEvent(TreePlantEvent.new(desc.index, px, py, pz, 0, ry, 0, stage, variation, nil, false, price, farmId))
                        end
                        spent = spent + price
                        planted = planted + 1
                        table.insert(placed, { px, pz })
                    end
                end
            end
        end
    end
    return planted
end

if ConstructionBrushTree ~= nil then
    -- allow dragging with the tree brush (single mode still plants one tree per click)
    ConstructionBrushTree.new = Utils.overwrittenFunction(ConstructionBrushTree.new, function(subclassMt, superFunc, cursor)
        local brush = superFunc(subclassMt, cursor)
        brush.supportsPrimaryDragging = true
        return brush
    end)

    ConstructionBrushTree.update = Utils.overwrittenFunction(ConstructionBrushTree.update, function(self, superFunc, dt)
        superFunc(self, dt)
        if self.cursor == nil then return end
        if treeCount() >= 2 then
            self.mbsScatter = true
            self.cursor:setShapeSize(MBS.scatterRadius * 2)
            if self.tree ~= nil then setVisibility(self.tree, false) end
        elseif self.mbsScatter then
            self.mbsScatter = false
            self.cursor:setShapeSize(1)
        end
    end)

    ConstructionBrushTree.onButtonPrimary = Utils.overwrittenFunction(ConstructionBrushTree.onButtonPrimary, function(self, superFunc, isDown, isDrag, isUp)
        if treeCount() >= 2 then
            if isUp then
                self.mbsLastX = nil
                return
            end
            local x, y, z = self.cursor:getHitTerrainPosition()
            if x == nil then return end
            if not isDown and self.mbsLastX ~= nil then
                local dx, dz = x - self.mbsLastX, z - self.mbsLastZ
                if dx * dx + dz * dz < (MBS.scatterRadius * 0.8) ^ 2 then return end
            end
            self.mbsLastX, self.mbsLastZ = x, z
            local ok, err = pcall(function()
                local planted = MBS.scatterTrees(self, x, y, z)
                if planted > 0 then
                    self:playSound(ConstructionSound.ID.TREE, 1 - (self.treeGrowthFactor or 0.5))
                    MBS.applyExtras("tree", self, x, y, z, MBS.scatterRadius, Landscaping.BRUSH_SHAPE.CIRCLE)
                end
            end)
            if not ok then Logging.warning('[MultiBrushSelect] scatter failed: %s', tostring(err)) end
            return
        end

        -- single tree: ignore drag / release, only the initial press plants
        if isDrag or isUp then return end
        local x, y, z = nil, nil, nil
        local willPlant = false
        if self.tree ~= nil and self.cursor ~= nil then
            x, y, z = self.cursor:getHitTerrainPosition()
            willPlant = x ~= nil and self:verifyPlacement(x, y, z) == nil
        end
        superFunc(self)
        if willPlant then
            local ok, err = pcall(function()
                MBS.applyExtras("tree", self, x, y, z, TREE_AROUND_RADIUS, Landscaping.BRUSH_SHAPE.CIRCLE)
            end)
            if not ok then Logging.warning('[MultiBrushSelect] tree extras failed: %s', tostring(err)) end
        end
    end)
end

addModEventListener(MBS)
