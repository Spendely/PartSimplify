-- Hi, Spendely here.
-- This plugin was fully made with Claude Opus 5.5, with only intelligent adjustments
-- and other changes made by me
-- I do not own this code, so feel free to open source and use it / adjust it, just do not republish as an identical
-- as roblox TOS nor me likes that, as theres doing something lazy, and then theres stealing.

-- This code is published to Roblox under https://www.roblox.com/users/2294046059/

-- This code is under GNU General Public License v3.0, you may reuse, republish, but you may not sell, and all modifications
-- must be public sourced and not blocked from modification.
local Selection = game:GetService("Selection")
local ChangeHistoryService = game:GetService("ChangeHistoryService")
local CollectionService = game:GetService("CollectionService")

local ICON_ID = "rbxassetid://0" -- TODO: replace with your icon decal id
local TITLE_FONT = Enum.Font.BuilderSansBold
local BODY_FONT = Enum.Font.BuilderSans
local MAX_SIZE = 2048 * 1000 -- max part size, in milli-studs
local PRECISION = 1000 -- positions snapped to 0.001 studs

------------------------------------------------------------------------
-- Settings
------------------------------------------------------------------------
local DEFAULTS = {
	SkipAnyChildren = false, -- skip parts with *anything* inside (even textures)
	AllowAttributesTags = false, -- merge parts with attributes/tags (must match exactly)
	IncludeLocked = false, -- merge locked parts too
	IgnoreWelds = false, -- merge welded parts (welds/snaps/glue/WeldConstraints on merged parts are removed)
}

local function getSetting(key)
	local v = plugin:GetSetting("Simplify_" .. key)
	if v == nil then
		return DEFAULTS[key]
	end
	return v
end

local function setSetting(key, value)
	plugin:SetSetting("Simplify_" .. key, value)
end

local function resetSettings()
	for key, value in pairs(DEFAULTS) do
		setSetting(key, value)
	end
end

------------------------------------------------------------------------
-- Part collection & stats
------------------------------------------------------------------------
local function collectParts()
	local parts, seen = {}, {}
	local function add(inst)
		if inst:IsA("BasePart") and not seen[inst] then
			seen[inst] = true
			table.insert(parts, inst)
		end
	end
	for _, inst in ipairs(Selection:Get()) do
		add(inst)
		for _, d in ipairs(inst:GetDescendants()) do
			add(d)
		end
	end
	return parts
end

local function worldExtents(part)
	local cf, s = part.CFrame, part.Size / 2
	local r, u, l = cf.RightVector, cf.UpVector, cf.LookVector
	return Vector3.new(
		math.abs(r.X) * s.X + math.abs(u.X) * s.Y + math.abs(l.X) * s.Z,
		math.abs(r.Y) * s.X + math.abs(u.Y) * s.Y + math.abs(l.Y) * s.Z,
		math.abs(r.Z) * s.X + math.abs(u.Z) * s.Y + math.abs(l.Z) * s.Z
	)
end

local function computeStats(parts)
	if #parts == 0 then
		return 0, 0, 0
	end
	local minV = Vector3.new(math.huge, math.huge, math.huge)
	local maxV = -minV
	for _, p in ipairs(parts) do
		local e = worldExtents(p)
		minV = minV:Min(p.Position - e)
		maxV = maxV:Max(p.Position + e)
	end
	local size = maxV - minV
	local volume = size.X * size.Y * size.Z
	local density = volume > 0 and #parts / volume or 0
	return #parts, volume, density
end

------------------------------------------------------------------------
-- Merge eligibility & grouping
------------------------------------------------------------------------
local function round(n, scale)
	return math.floor(n * scale + 0.5)
end

local function c3(c)
	return string.format("%d,%d,%d", round(c.R, 255), round(c.G, 255), round(c.B, 255))
end

local FACES = { "TopSurface", "BottomSurface", "LeftSurface", "RightSurface", "FrontSurface", "BackSurface" }

-- Joint types that only glue parts together; ignorable via the IgnoreWelds setting.
local WELD_CLASSES = { Weld = true, ManualWeld = true, Snap = true, Glue = true, WeldConstraint = true }

local function isIgnoredWeld(inst)
	return WELD_CLASSES[inst.ClassName] == true and getSetting("IgnoreWelds")
end

-- Removes every weld touching a part (inside it, or in other parts pointing at it).
local function dropWelds(part)
	for _, j in ipairs(part:GetJoints()) do
		if WELD_CLASSES[j.ClassName] then
			j.Parent = nil -- undoable, unlike Destroy()
		end
	end
	for _, child in ipairs(part:GetChildren()) do
		if WELD_CLASSES[child.ClassName] then
			child.Parent = nil
		end
	end
end

-- Returns a signature string for the part's textures, or nil if the part has
-- children that make it unmergeable.
local function childrenSignature(part)
	local children = {}
	for _, child in ipairs(part:GetChildren()) do
		if not isIgnoredWeld(child) then
			table.insert(children, child)
		end
	end
	if #children == 0 then
		return ""
	end
	if getSetting("SkipAnyChildren") then
		return nil
	end
	local sigs = {}
	for _, child in ipairs(children) do
		-- Only Textures tile over a bigger face cleanly; Decals would stretch, so they block merging.
		if child.ClassName ~= "Texture" or #child:GetChildren() > 0 then
			return nil
		end
		table.insert(sigs, table.concat({
			child.Face.Name, child.Texture, c3(child.Color3),
			round(child.Transparency, 1000), round(child.StudsPerTileU, 1000), round(child.StudsPerTileV, 1000),
			round(child.OffsetStudsU, 1000), round(child.OffsetStudsV, 1000), child.ZIndex,
		}, "|"))
	end
	table.sort(sigs)
	return table.concat(sigs, ";")
end

local function attributesSignature(part)
	local attrs = part:GetAttributes()
	local tags = CollectionService:GetTags(part)
	if next(attrs) == nil and #tags == 0 then
		return ""
	end
	if not getSetting("AllowAttributesTags") then
		return nil
	end
	local out = {}
	for k, v in pairs(attrs) do
		table.insert(out, k .. "=" .. typeof(v) .. ":" .. tostring(v))
	end
	table.sort(out)
	table.sort(tags)
	return table.concat(out, ";") .. "#" .. table.concat(tags, ";")
end

-- Returns the grouping key for a part, or nil if the part must be left alone.
local function groupKey(part)
	if part.ClassName ~= "Part" or part.Shape ~= Enum.PartType.Block then
		return nil
	end
	if part.Locked and not getSetting("IncludeLocked") then
		return nil
	end
	for _, j in ipairs(part:GetJoints()) do -- jointed parts are referenced elsewhere
		if not isIgnoredWeld(j) then
			return nil
		end
	end
	local children = childrenSignature(part)
	if not children then
		return nil
	end
	local attrs = attributesSignature(part)
	if not attrs then
		return nil
	end

	local rot = {}
	local cf = part.CFrame
	if children == "" then
		-- Describe the part by which surface faces which world direction. A block turned
		-- 90°/180° that still shows the same faces the same way (e.g. studs up, inlets
		-- down, spun around Y) gets the same key, so it can merge with its neighbours.
		local faceDirs = {
			TopSurface = cf.UpVector, BottomSurface = -cf.UpVector,
			RightSurface = cf.RightVector, LeftSurface = -cf.RightVector,
			FrontSurface = cf.LookVector, BackSurface = -cf.LookVector,
		}
		for _, f in ipairs(FACES) do
			local v = faceDirs[f]
			rot[#rot + 1] = string.format("%d,%d,%d=%s", round(v.X, 10000), round(v.Y, 10000), round(v.Z, 10000), part[f].Name)
		end
		table.sort(rot)
	else
		-- Textures also have an in-face orientation, so require the exact rotation.
		local comps = { cf.Rotation:GetComponents() }
		for i = 4, 12 do
			rot[#rot + 1] = round(comps[i], 10000)
		end
		for _, f in ipairs(FACES) do
			rot[#rot + 1] = part[f].Name
		end
	end

	local phys = part.CustomPhysicalProperties
	return table.concat({
		part.Parent and part.Parent:GetDebugId() or "nil",
		table.concat(rot, ";"),
		c3(part.Color),
		part.Material.Name,
		part.MaterialVariant,
		round(part.Transparency, 1000),
		round(part.Reflectance, 1000),
		tostring(part.CanCollide), tostring(part.CanQuery), tostring(part.CanTouch),
		tostring(part.Anchored), tostring(part.Massless), tostring(part.Locked),
		part.CollisionGroup,
		phys and tostring(phys) or "none",
		children,
		attrs,
	}, "\0")
end

------------------------------------------------------------------------
-- Merging
------------------------------------------------------------------------
local OTHER = { { 2, 3 }, { 1, 3 }, { 1, 2 } }

local function faceKey(box, axis, value)
	local o = OTHER[axis]
	return string.format("%d|%d|%d|%d|%d", value, box.min[o[1]], box.max[o[1]], box.min[o[2]], box.max[o[2]])
end

-- Repeatedly fuses pairs of boxes that share an entire face. Chained merges cover
-- rows of bricks, filled grids/cubes, and L-shapes that complete into rectangles
-- (e.g. 3 x 1x1x1 -> 1x3x1, then 1x3x1 + 1x3x1 -> 2x3x1).
local function mergeBoxes(boxes)
	local changed = true
	while changed do
		changed = false
		for axis = 1, 3 do
			local byMin = {}
			for _, b in ipairs(boxes) do
				if b.alive then
					local k = faceKey(b, axis, b.min[axis])
					if byMin[k] == nil then
						byMin[k] = b
					end
				end
			end
			for _, a in ipairs(boxes) do
				while a.alive do
					local k = faceKey(a, axis, a.max[axis])
					local b = byMin[k]
					if not b or b == a or not b.alive or b.max[axis] - a.min[axis] > MAX_SIZE then
						break
					end
					byMin[k] = nil
					a.max[axis] = b.max[axis]
					a.castShadow = a.castShadow or b.castShadow
					a.merged = true
					b.alive = false
					changed = true
				end
			end
		end
	end
end

-- Advanced mode: treat the whole group as one solid volume and re-cut it into as few
-- boxes as possible. Handles staggered bricks (running bond), walls with window holes,
-- overlapping parts, etc. - anything where the parts' union can be covered by fewer boxes.
local CELL_LIMIT = 1500000
local ORDERS = { { 1, 2, 3 }, { 1, 3, 2 }, { 2, 1, 3 }, { 2, 3, 1 }, { 3, 1, 2 }, { 3, 2, 1 } }

local function decomposeBoxes(boxes)
	-- Coordinate compression: every distinct face position becomes a grid line.
	local coords, index = { {}, {}, {} }, { {}, {}, {} }
	for axis = 1, 3 do
		local set = {}
		for _, b in ipairs(boxes) do
			set[b.min[axis]] = true
			set[b.max[axis]] = true
		end
		for v in pairs(set) do
			table.insert(coords[axis], v)
		end
		table.sort(coords[axis])
		for i, v in ipairs(coords[axis]) do
			index[axis][v] = i
		end
	end
	local n = { #coords[1] - 1, #coords[2] - 1, #coords[3] - 1 }
	if n[1] * n[2] * n[3] > CELL_LIMIT then
		return nil
	end

	local function cell(i, j, k)
		return i + (j - 1) * n[1] + (k - 1) * n[1] * n[2]
	end

	local filled = {}
	for _, b in ipairs(boxes) do
		for k = index[3][b.min[3]], index[3][b.max[3]] - 1 do
			for j = index[2][b.min[2]], index[2][b.max[2]] - 1 do
				for i = index[1][b.min[1]], index[1][b.max[1]] - 1 do
					filled[cell(i, j, k)] = true
				end
			end
		end
	end

	local function run(order)
		local used = {}
		local function free(lo, hi)
			for k = lo[3], hi[3] do
				for j = lo[2], hi[2] do
					for i = lo[1], hi[1] do
						local c = cell(i, j, k)
						if not filled[c] or used[c] then
							return false
						end
					end
				end
			end
			return true
		end

		local out = {}
		for k = 1, n[3] do
			for j = 1, n[2] do
				for i = 1, n[1] do
					local c = cell(i, j, k)
					if filled[c] and not used[c] then
						local lo, hi = { i, j, k }, { i, j, k }
						for _, ax in ipairs(order) do
							while hi[ax] < n[ax] and coords[ax][hi[ax] + 2] - coords[ax][lo[ax]] <= MAX_SIZE do
								local sLo, sHi = table.clone(lo), table.clone(hi)
								sLo[ax], sHi[ax] = hi[ax] + 1, hi[ax] + 1
								if not free(sLo, sHi) then
									break
								end
								hi[ax] += 1
							end
						end
						for kk = lo[3], hi[3] do
							for jj = lo[2], hi[2] do
								for ii = lo[1], hi[1] do
									used[cell(ii, jj, kk)] = true
								end
							end
						end
						table.insert(out, {
							min = { coords[1][lo[1]], coords[2][lo[2]], coords[3][lo[3]] },
							max = { coords[1][hi[1] + 1], coords[2][hi[2] + 1], coords[3][hi[3] + 1] },
						})
					end
				end
			end
		end
		return out
	end

	local best
	for _, order in ipairs(ORDERS) do
		-- The greedy cut can leave stacked strips that share a whole face
		-- (e.g. three slabs between two windows); fuse those back together.
		local cut = run(order)
		for _, b in ipairs(cut) do
			b.alive = true
		end
		mergeBoxes(cut)
		local result = {}
		for _, b in ipairs(cut) do
			if b.alive then
				table.insert(result, b)
			end
		end
		if not best or #result < #best then
			best = result
		end
	end
	return best
end

local function boxCFrame(rot, b)
	local mn = Vector3.new(b.min[1], b.min[2], b.min[3]) / PRECISION
	local mx = Vector3.new(b.max[1], b.max[2], b.max[3]) / PRECISION
	return mx - mn, rot * CFrame.new((mn + mx) / 2)
end

-- Replaces a group's parts with clones of the first part cut to the new boxes.
-- Returns the number of parts removed, or nil if it wasn't worth it / possible.
local function advancedGroup(g)
	local newBoxes = decomposeBoxes(g.boxes)
	if not newBoxes or #newBoxes >= #g.boxes then
		return nil
	end
	local castShadow = false
	for _, b in ipairs(g.boxes) do
		castShadow = castShadow or b.castShadow
	end
	for _, b in ipairs(g.boxes) do
		dropWelds(b.part)
	end
	local template = g.boxes[1].part
	local parent = template.Parent
	local archivable = template.Archivable
	template.Archivable = true
	for _, b in ipairs(newBoxes) do
		local p = template:Clone()
		p.Size, p.CFrame = boxCFrame(g.rot, b)
		p.CastShadow = castShadow
		p.Parent = parent
		p.Archivable = archivable
	end
	for _, b in ipairs(g.boxes) do
		b.part.Parent = nil -- not Destroy(): destroyed instances can't be restored by Undo
	end
	return #g.boxes - #newBoxes
end

local function simplify(parts, advanced)
	local groups = {}
	for _, part in ipairs(parts) do
		local key = groupKey(part)
		if key then
			local g = groups[key]
			if not g then
				g = { rot = part.CFrame.Rotation, boxes = {} }
				groups[key] = g
			end
			local lp = g.rot:PointToObjectSpace(part.Position)
			-- Half-size in the group frame (axes line up, but may be flipped/swapped)
			local rel = g.rot:ToObjectSpace(part.CFrame)
			local s = part.Size / 2
			local r, u, l = rel.RightVector, rel.UpVector, rel.LookVector
			local h = Vector3.new(
				math.abs(r.X) * s.X + math.abs(u.X) * s.Y + math.abs(l.X) * s.Z,
				math.abs(r.Y) * s.X + math.abs(u.Y) * s.Y + math.abs(l.Y) * s.Z,
				math.abs(r.Z) * s.X + math.abs(u.Z) * s.Y + math.abs(l.Z) * s.Z
			)
			table.insert(g.boxes, {
				part = part,
				alive = true,
				castShadow = part.CastShadow,
				min = { round(lp.X - h.X, PRECISION), round(lp.Y - h.Y, PRECISION), round(lp.Z - h.Z, PRECISION) },
				max = { round(lp.X + h.X, PRECISION), round(lp.Y + h.Y, PRECISION), round(lp.Z + h.Z, PRECISION) },
			})
		end
	end

	local removed = 0
	for _, g in pairs(groups) do
		local advRemoved = advanced and #g.boxes > 1 and advancedGroup(g)
		if advRemoved then
			removed += advRemoved
		elseif #g.boxes > 1 then
			mergeBoxes(g.boxes)
			for _, b in ipairs(g.boxes) do
				if not b.alive then
					dropWelds(b.part)
					b.part.Parent = nil -- undoable, unlike Destroy()
					removed += 1
				elseif b.merged then
					dropWelds(b.part)
					b.part.Size, b.part.CFrame = boxCFrame(g.rot, b)
					b.part.CastShadow = b.castShadow
				end
			end
		end
	end
	return removed
end

------------------------------------------------------------------------
-- UI
------------------------------------------------------------------------
local toolbar = plugin:CreateToolbar("Simplify")
local button = toolbar:CreateButton("Simplify", "Merge identical touching parts", ICON_ID)
button.ClickableWhenViewportHidden = true

local widget = plugin:CreateDockWidgetPluginGui(
	"SimplifyWidget",
	DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Float, false, false, 300, 560, 240, 300)
)
widget.Title = "Simplify"

local Theme = settings().Studio.Theme
local C = Enum.StudioStyleGuideColor
local function col(c, m)
	return Theme:GetColor(c, m)
end

local root = Instance.new("Frame")
root.Size = UDim2.fromScale(1, 1)
root.BorderSizePixel = 0
root.Parent = widget

local function new(class, props, parent)
	local inst = Instance.new(class)
	for k, v in pairs(props) do
		inst[k] = v
	end
	inst.Parent = parent
	return inst
end

local function corner(parent)
	new("UICorner", { CornerRadius = UDim.new(0, 4) }, parent)
end

local themed = {} -- {inst, prop, color, modifier}
local function theme(inst, prop, c, m)
	table.insert(themed, { inst, prop, c, m })
	inst[prop] = col(c, m)
end
local function applyTheme()
	Theme = settings().Studio.Theme
	for _, t in ipairs(themed) do
		t[1][t[2]] = col(t[3], t[4])
	end
end
theme(root, "BackgroundColor3", C.MainBackground)

local function label(text, size, font, parent, order)
	local l = new("TextLabel", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, size + 6),
		Font = font,
		TextSize = size,
		Text = text,
		TextWrapped = true,
		LayoutOrder = order or 0,
	}, parent)
	theme(l, "TextColor3", C.MainText)
	return l
end

local function bigButton(text, parent, order)
	local b = new("TextButton", {
		Size = UDim2.new(0, 200, 0, 44),
		Font = TITLE_FONT,
		TextSize = 18,
		Text = text,
		AutoButtonColor = true,
		LayoutOrder = order or 0,
	}, parent)
	corner(b)
	theme(b, "BackgroundColor3", C.Button)
	theme(b, "TextColor3", C.ButtonText)
	new("UIStroke", { ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Transparency = 0.6 }, b)
	return b
end

local function checkbox(text, initial, parent, order, onChanged)
	local row = new("TextButton", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 24),
		Text = "",
		LayoutOrder = order or 0,
	}, parent)
	local box = new("Frame", { Size = UDim2.fromOffset(18, 18), Position = UDim2.new(0, 0, 0.5, -9) }, row)
	corner(box)
	theme(box, "BackgroundColor3", C.InputFieldBackground)
	new("UIStroke", { Transparency = 0.5 }, box)
	local tick = new("TextLabel", {
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Font = TITLE_FONT,
		TextSize = 14,
		Text = "✓",
	}, box)
	theme(tick, "TextColor3", C.MainText)
	local l = new("TextLabel", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(26, 0),
		Size = UDim2.new(1, -26, 1, 0),
		Font = BODY_FONT,
		TextSize = 15,
		Text = text,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextWrapped = true,
	}, row)
	theme(l, "TextColor3", C.MainText)

	local state = initial
	local function set(v)
		state = v
		tick.Visible = v
	end
	set(initial)
	row.MouseButton1Click:Connect(function()
		set(not state)
		if onChanged then
			onChanged(state)
		end
	end)
	return {
		get = function()
			return state
		end,
		set = set,
	}
end

-- Welcome page ---------------------------------------------------------
local welcome = new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) }, root)
new("UIListLayout", {
	FillDirection = Enum.FillDirection.Vertical,
	HorizontalAlignment = Enum.HorizontalAlignment.Center,
	VerticalAlignment = Enum.VerticalAlignment.Center,
	SortOrder = Enum.SortOrder.LayoutOrder,
	Padding = UDim.new(0, 12),
}, welcome)
new("ImageLabel", { BackgroundTransparency = 1, Size = UDim2.fromOffset(150, 150), Image = ICON_ID, LayoutOrder = 1 }, welcome)
label("Welcome to Simplify!", 26, TITLE_FONT, welcome, 2)
local startButton = bigButton("Click to Start", welcome, 3)
local resetHolder = new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(150, 24), LayoutOrder = 4 }, welcome)
local resetBox = checkbox("Reset Settings?", false, resetHolder)

-- Main page -------------------------------------------------------------
local main = new("ScrollingFrame", {
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	Size = UDim2.fromScale(1, 1),
	CanvasSize = UDim2.new(),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	ScrollBarThickness = 6,
	Visible = false,
}, root)
new("UIPadding", {
	PaddingTop = UDim.new(0, 16), PaddingBottom = UDim.new(0, 16),
	PaddingLeft = UDim.new(0, 16), PaddingRight = UDim.new(0, 16),
}, main)
new("UIListLayout", {
	HorizontalAlignment = Enum.HorizontalAlignment.Center,
	SortOrder = Enum.SortOrder.LayoutOrder,
	Padding = UDim.new(0, 10),
}, main)

local header = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 64), LayoutOrder = 1 }, main)
new("UIListLayout", {
	FillDirection = Enum.FillDirection.Horizontal,
	HorizontalAlignment = Enum.HorizontalAlignment.Center,
	VerticalAlignment = Enum.VerticalAlignment.Center,
	Padding = UDim.new(0, 10),
}, header)
new("ImageLabel", { BackgroundTransparency = 1, Size = UDim2.fromOffset(56, 56), Image = ICON_ID }, header)
local titleLabel = label("Simplify", 32, TITLE_FONT, header)
titleLabel.Size = UDim2.fromOffset(140, 56)
titleLabel.TextXAlignment = Enum.TextXAlignment.Left

local statsFrame = new("Frame", { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 2 }, main)
corner(statsFrame)
theme(statsFrame, "BackgroundColor3", C.Item)
new("UIPadding", {
	PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8),
	PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10),
}, statsFrame)
new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 2) }, statsFrame)
local countLabel = label("", 16, BODY_FONT, statsFrame, 1)
local volumeLabel = label("", 16, BODY_FONT, statsFrame, 2)
local densityLabel = label("", 16, BODY_FONT, statsFrame, 3)
for _, l in ipairs({ countLabel, volumeLabel, densityLabel }) do
	l.TextXAlignment = Enum.TextXAlignment.Left
end

local simplifyButton = bigButton("Simplify Parts", main, 3)
local advancedButton = bigButton("Advanced Simplify", main, 3.1)
local advancedHint = label("Re-cuts matching parts into the fewest boxes: staggered bricks, walls with windows, overlaps.", 13, BODY_FONT, main, 3.2)
advancedHint.AutomaticSize = Enum.AutomaticSize.Y
theme(advancedHint, "TextColor3", C.DimmedText)
local statusLabel = label("", 14, BODY_FONT, main, 4)
statusLabel.AutomaticSize = Enum.AutomaticSize.Y
theme(statusLabel, "TextColor3", C.DimmedText)

local settingsTitle = label("Settings", 18, TITLE_FONT, main, 5)
settingsTitle.TextXAlignment = Enum.TextXAlignment.Left

local toggles = {}
local function settingToggle(key, text, order)
	local t = checkbox(text, getSetting(key), main, order, function(v)
		setSetting(key, v)
	end)
	toggles[key] = t
end
settingToggle("SkipAnyChildren", "Skip parts with anything inside them", 6)
settingToggle("AllowAttributesTags", "Merge parts with attributes / tags", 7)
settingToggle("IncludeLocked", "Merge locked parts", 8)
settingToggle("IgnoreWelds", "Ignore welds / snaps / weld constraints", 9)

------------------------------------------------------------------------
-- Behaviour
------------------------------------------------------------------------
local function refreshStats()
	if not main.Visible then
		return
	end
	local count, volume, density = computeStats(collectParts())
	countLabel.Text = string.format("Parts: %d", count)
	volumeLabel.Text = string.format("Area volume: %s studs³", string.format("%.1f", volume))
	densityLabel.Text = string.format("Parts per stud³: %.5f", density)
end

startButton.MouseButton1Click:Connect(function()
	if resetBox.get() then
		resetSettings()
		for key, t in pairs(toggles) do
			t.set(getSetting(key))
		end
		resetBox.set(false)
	end
	welcome.Visible = false
	main.Visible = true
	refreshStats()
end)

local function runSimplify(advanced)
	local parts = collectParts()
	if #parts == 0 then
		statusLabel.Text = "Select something first."
		return
	end
	local before = #parts
	local recording = ChangeHistoryService:TryBeginRecording(advanced and "Advanced Simplify Parts" or "Simplify Parts")
	if not recording then
		statusLabel.Text = "Couldn't start an undo recording (is another action or playtest running?). Nothing was changed."
		return
	end
	local ok, result = pcall(simplify, parts, advanced)
	-- Commit even on error so a partial run can still be undone with Ctrl+Z.
	ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
	if ok then
		statusLabel.Text = string.format("Merged away %d parts (%d → %d).", result, before, before - result)
	else
		statusLabel.Text = "Error: " .. tostring(result)
	end
	refreshStats()
end

simplifyButton.MouseButton1Click:Connect(function()
	runSimplify(false)
end)
advancedButton.MouseButton1Click:Connect(function()
	runSimplify(true)
end)

Selection.SelectionChanged:Connect(refreshStats)
settings().Studio.ThemeChanged:Connect(applyTheme)

button.Click:Connect(function()
	widget.Enabled = not widget.Enabled
	if widget.Enabled then
		welcome.Visible = true
		main.Visible = false
	end
end)
widget:GetPropertyChangedSignal("Enabled"):Connect(function()
	button:SetActive(widget.Enabled)
end)
