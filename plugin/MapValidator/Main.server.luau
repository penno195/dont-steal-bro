--!strict
-- The Studio half of the map validator (P7-1). MapCheck.luau owns every
-- rule; this script only does what needs a live Studio: pick the map,
-- load the config it's checked against, run the reachability check
-- through PathfindingService, and render the Report as a clickable list
-- in a dock widget. Build and install: docs/map-validator.md.
--
-- Clicking a finding selects every offending instance in the Explorer;
-- a finding with no instance (a fall-through gap) moves the camera to
-- it instead.

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local PathfindingService = game:GetService("PathfindingService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Selection = game:GetService("Selection")
local ServerStorage = game:GetService("ServerStorage")

local MapCheck = require(script.Parent.MapCheck)
local Snapshot = require(script.Parent.Snapshot)

-- ===== config ================================================================

type Config = { taskIds: { string }, powerUps: { MapCheck.PowerUpLite }, mapDefs: { [string]: any } }

-- Each def file is required through a fresh Clone: a plugin caches
-- `require` per ModuleScript for the whole Studio session, so requiring
-- the originals would validate against whatever the config said when
-- the plugin loaded, not what Rojo has synced since. The registry
-- init.luau files are skipped for the same reason - they'd return the
-- cached list - and walked here directly instead. The clone sits next
-- to its original only while it's required; the caller wraps this in a
-- cancelled ChangeHistory recording so none of that reaches undo.
local function loadDefs(config: Instance, name: string): { any }
	local folder = config:FindFirstChild(name)
	if folder == nil then
		error(string.format("Config.%s is missing", name))
	end
	local defs = {}
	for _, child in (folder :: Instance):GetChildren() do
		if child:IsA("ModuleScript") then
			local clone = child:Clone()
			clone.Parent = folder
			local ok, def = pcall(require, clone)
			clone:Destroy()
			if not ok then
				error(string.format("Config.%s.%s: %s", name, child.Name, tostring(def)))
			end
			table.insert(defs, def)
		end
	end
	return defs
end

local function loadConfig(): (Config?, string?)
	local shared = ReplicatedStorage:FindFirstChild("Shared")
	local configFolder = shared and shared:FindFirstChild("Config")
	if configFolder == nil then
		return nil, "ReplicatedStorage.Shared.Config is missing - is Rojo synced?"
	end
	local recording = ChangeHistoryService:TryBeginRecording("MapValidatorConfig", "Map validator config load")
	if recording == nil then
		return nil, "another ChangeHistory recording is in progress"
	end
	local config: Config = { taskIds = {}, powerUps = {}, mapDefs = {} }
	local ok, err = pcall(function()
		for _, def in loadDefs(configFolder :: Instance, "Tasks") do
			table.insert(config.taskIds, def.id)
		end
		for _, def in loadDefs(configFolder :: Instance, "PowerUps") do
			table.insert(config.powerUps, { id = def.id, rarity = def.rarity })
		end
		-- Matched to the model by def.id == model Name, as ConfigValidator
		-- and scripts/validate-maps.luau both do.
		for _, def in loadDefs(configFolder :: Instance, "Maps") do
			config.mapDefs[def.id] = def
		end
	end)
	ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Cancel)
	if not ok then
		return nil, "couldn't load config: " .. tostring(err)
	end
	return config
end

-- ===== reachability ==========================================================

local function toVector3(p: MapCheck.Vec3): Vector3
	return Vector3.new(p.x, p.y, p.z)
end

-- Pathfinding only sees geometry in Workspace, and the check wants kill
-- zones treated as walls, which means adding PathfindingModifiers. Both
-- are edits to the place, so everything happens inside one
-- ChangeHistory recording that's cancelled at the end: the clone and
-- the modifiers are reverted and never reach the undo stack.
--
-- Returns nil plus a reason when the check couldn't run, which MapCheck
-- reports as skipped - never as passed.
local function findUnreachable(
	map: Instance,
	snapshot: MapCheck.MapSnapshot,
	progress: (string) -> ()
): ({ number }?, string?)
	local starts, targets = MapCheck.reachabilityProbes(snapshot)
	if #starts == 0 or #targets == 0 then
		-- Tags already fails the map for missing spawns or stations;
		-- nothing here would add to that.
		return {}
	end

	local recording = ChangeHistoryService:TryBeginRecording("MapValidatorReachability", "Map validator reachability")
	if recording == nil then
		return nil, "another ChangeHistory recording is in progress"
	end

	local root = map
	local cloned: Instance? = nil
	if not map:IsDescendantOf(workspace) then
		local copy = map:Clone()
		copy.Parent = workspace
		cloned = copy
		root = copy
	end

	local modifiers: { Instance } = {}
	for _, instance in root:GetDescendants() do
		if instance:IsA("BasePart") and instance:HasTag("KillZone") then
			local modifier = Instance.new("PathfindingModifier")
			modifier.Label = "KillZone"
			modifier.Parent = instance
			table.insert(modifiers, modifier)
		end
	end

	local params = table.clone(MapCheck.PATH_AGENT) :: { [string]: any }
	params.Costs = { KillZone = math.huge }
	local path = PathfindingService:CreatePath(params)

	local unreachable: { number } = {}
	local ok, err = pcall(function()
		for i, target in targets do
			progress(string.format("Pathfinding %d/%d...", i, #targets))
			for _, start in starts do
				local computed = pcall(function()
					path:ComputeAsync(toVector3(start.point), toVector3(target.point))
				end)
				local status = if computed then path.Status else nil
				if status ~= Enum.PathStatus.Success then
					-- Full detail to Output; the report just lists targets.
					print(
						string.format(
							"[MapValidator] %s unreachable from %s (%s)",
							snapshot.nodes[target.id].path,
							snapshot.nodes[start.id].path,
							if status then status.Name else "ComputeAsync errored"
						)
					)
					table.insert(unreachable, target.id)
					break
				end
			end
		end
	end)

	for _, modifier in modifiers do
		modifier:Destroy()
	end
	if cloned then
		cloned:Destroy()
	end
	ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Cancel)

	if not ok then
		return nil, "pathfinding failed: " .. tostring(err)
	end
	return unreachable
end

-- ===== picking the map =======================================================

local function mapsFolder(): Instance?
	return ServerStorage:FindFirstChild("Maps")
end

-- The map a selection belongs to: the Model under ServerStorage.Maps
-- that contains it, or failing that the selected Model itself (a map
-- being built in Workspace before it's moved into Maps).
local function mapForSelection(): Instance?
	local selected = Selection:Get()[1]
	if selected == nil then
		return nil
	end
	local folder = mapsFolder()
	local current: Instance? = selected
	while current ~= nil do
		if current.Parent == folder and current:IsA("Model") then
			return current
		end
		current = current.Parent
	end
	return if selected:IsA("Model") then selected else nil
end

-- ===== widget ================================================================

local theme = settings().Studio.Theme
local function color(item: Enum.StudioStyleGuideColor): Color3
	return theme:GetColor(item)
end

local SEVERITY_COLOR: { [string]: Color3 } = {
	error = Color3.fromRGB(235, 87, 87),
	warning = Color3.fromRGB(242, 181, 60),
	info = Color3.fromRGB(150, 150, 150),
}

local toolbar = plugin:CreateToolbar("Don't Steal Bro!")
local toggleButton = toolbar:CreateButton("MapValidator", "Validate a map against map-kit-spec.md", "", "Map Validator")
toggleButton.ClickableWhenViewportHidden = true

local widget = plugin:CreateDockWidgetPluginGuiAsync(
	"DontStealBroMapValidator",
	DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Right, false, false, 360, 480, 280, 240)
)
widget.Title = "Map Validator"

local root = Instance.new("Frame")
root.Size = UDim2.fromScale(1, 1)
root.BackgroundColor3 = color(Enum.StudioStyleGuideColor.MainBackground)
root.BorderSizePixel = 0
root.Parent = widget

local function button(text: string, x: number): TextButton
	local b = Instance.new("TextButton")
	b.Text = text
	b.Size = UDim2.new(0.5, -6, 0, 28)
	b.Position = UDim2.new(x, 4, 0, 4)
	b.BackgroundColor3 = color(Enum.StudioStyleGuideColor.Button)
	b.TextColor3 = color(Enum.StudioStyleGuideColor.ButtonText)
	b.Font = Enum.Font.SourceSansSemibold
	b.TextSize = 15
	b.Parent = root
	return b
end

local validateSelected = button("Validate selected", 0)
local validateAll = button("Validate all maps", 0.5)

local summary = Instance.new("TextLabel")
summary.Size = UDim2.new(1, -8, 0, 40)
summary.Position = UDim2.fromOffset(4, 36)
summary.BackgroundTransparency = 1
summary.TextColor3 = color(Enum.StudioStyleGuideColor.MainText)
summary.Font = Enum.Font.SourceSansBold
summary.TextSize = 16
summary.TextWrapped = true
summary.TextXAlignment = Enum.TextXAlignment.Left
summary.Text = "Select a map (or anything inside one) and validate."
summary.Parent = root

local list = Instance.new("ScrollingFrame")
list.Size = UDim2.new(1, 0, 1, -80)
list.Position = UDim2.fromOffset(0, 80)
list.BackgroundTransparency = 1
list.BorderSizePixel = 0
list.ScrollBarThickness = 8
list.CanvasSize = UDim2.new()
list.AutomaticCanvasSize = Enum.AutomaticSize.Y
list.Parent = root

local layout = Instance.new("UIListLayout")
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Padding = UDim.new(0, 2)
layout.Parent = list

local rowCount = 0
local function addRow(text: string, textColor: Color3, bold: boolean, onClick: (() -> ())?)
	rowCount += 1
	local row = Instance.new("TextButton")
	row.LayoutOrder = rowCount
	row.Size = UDim2.new(1, -12, 0, 0)
	row.AutomaticSize = Enum.AutomaticSize.Y
	row.BackgroundTransparency = if onClick then 0 else 1
	row.BackgroundColor3 = color(Enum.StudioStyleGuideColor.Item)
	row.BorderSizePixel = 0
	row.AutoButtonColor = onClick ~= nil
	row.Text = text
	row.TextColor3 = textColor
	row.Font = if bold then Enum.Font.SourceSansBold else Enum.Font.SourceSans
	row.TextSize = 14
	row.TextWrapped = true
	row.TextXAlignment = Enum.TextXAlignment.Left
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 6)
	pad.PaddingTop = UDim.new(0, 3)
	pad.PaddingBottom = UDim.new(0, 3)
	pad.Parent = row
	if onClick then
		row.Activated:Connect(onClick)
	end
	row.Parent = list
end

local function clearRows()
	for _, child in list:GetChildren() do
		if child:IsA("TextButton") then
			child:Destroy()
		end
	end
	rowCount = 0
end

local function focusCamera(p: MapCheck.Vec3)
	local camera = workspace.CurrentCamera
	local target = toVector3(p)
	camera.CFrame = CFrame.lookAt(target + Vector3.new(0, 25, 25), target)
	camera.Focus = CFrame.new(target)
end

local function renderReport(report: MapCheck.Report, instances: { any })
	local mainText = color(Enum.StudioStyleGuideColor.MainText)
	addRow(report.summary, if report.passed then Color3.fromRGB(80, 200, 120) else SEVERITY_COLOR.error, true, nil)
	local lastCategory = ""
	for _, finding in report.findings do
		if finding.category ~= lastCategory then
			addRow(finding.category, mainText, true, nil)
			lastCategory = finding.category
		end
		local selectable = {}
		for _, id in finding.nodeIds do
			local instance = instances[id]
			if instance ~= nil and instance.Parent ~= nil then
				table.insert(selectable, instance)
			end
		end
		local suffix = ""
		if #selectable > 0 then
			suffix = string.format("  [select %d]", #selectable)
		elseif #finding.positions > 0 then
			suffix = "  [go to]"
		end
		local onClick: (() -> ())? = nil
		if #selectable > 0 then
			onClick = function()
				Selection:Set(selectable)
			end
		elseif #finding.positions > 0 then
			onClick = function()
				focusCamera(finding.positions[1])
			end
		end
		addRow(
			string.format("%s  %s%s", string.upper(finding.severity), finding.message, suffix),
			SEVERITY_COLOR[finding.severity],
			false,
			onClick
		)
	end
end

-- ===== running ===============================================================

local busy = false

local function validate(maps: { Instance })
	if busy then
		return
	end
	busy = true
	clearRows()
	summary.TextColor3 = color(Enum.StudioStyleGuideColor.MainText)

	local config, configErr = loadConfig()
	if config == nil then
		summary.Text = "FAIL " .. tostring(configErr)
		busy = false
		return
	end

	local failed = 0
	for i, map in maps do
		summary.Text = string.format("Validating %s (%d/%d)...", map.Name, i, #maps)
		local snapshot, instances = Snapshot.build(map)
		local unreachable, reason = findUnreachable(map, snapshot, function(step)
			summary.Text = string.format("Validating %s (%d/%d): %s", map.Name, i, #maps, step)
		end)
		if reason then
			warn(string.format("[MapValidator] %s: reachability skipped - %s", map.Name, reason))
		end
		local report = MapCheck.run(snapshot, {
			taskIds = config.taskIds,
			powerUps = config.powerUps,
			mapDef = config.mapDefs[map.Name],
			unreachableIds = unreachable,
		})
		print(MapCheck.formatText(report))
		renderReport(report, instances)
		if not report.passed then
			failed += 1
		end
	end

	if #maps == 1 then
		summary.Text = (list:FindFirstChildWhichIsA("TextButton") :: TextButton).Text
	else
		summary.Text =
			string.format("%s - %d map(s) checked, %d failed", if failed == 0 then "PASS" else "FAIL", #maps, failed)
	end
	summary.TextColor3 = if failed == 0 then Color3.fromRGB(80, 200, 120) else SEVERITY_COLOR.error
	busy = false
end

validateSelected.Activated:Connect(function()
	local map = mapForSelection()
	if map == nil then
		summary.TextColor3 = color(Enum.StudioStyleGuideColor.MainText)
		summary.Text = "Select a map Model under ServerStorage.Maps, or anything inside one."
		return
	end
	validate({ map })
end)

validateAll.Activated:Connect(function()
	local folder = mapsFolder()
	local maps: { Instance } = {}
	if folder ~= nil then
		for _, child in folder:GetChildren() do
			if child:IsA("Model") then
				table.insert(maps, child)
			end
		end
	end
	table.sort(maps, function(a, b)
		return a.Name < b.Name
	end)
	if #maps == 0 then
		summary.TextColor3 = SEVERITY_COLOR.error
		summary.Text = "FAIL no map Models under ServerStorage.Maps"
		return
	end
	validate(maps)
end)

toggleButton.Click:Connect(function()
	widget.Enabled = not widget.Enabled
end)
widget:GetPropertyChangedSignal("Enabled"):Connect(function()
	toggleButton:SetActive(widget.Enabled)
end)
toggleButton:SetActive(widget.Enabled)
