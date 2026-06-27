local ChangeHistoryService = game:GetService('ChangeHistoryService')
local Selection = game:GetService('Selection')
local UserInputService = game:GetService('UserInputService')

local Plugin = script.Parent.Parent

local React = require(Plugin.Packages.React)

local Util = Plugin.Util
local Constants = require(Util.Constants)
local Localization = require(Util.Localization)
local Settings = require(Util.Settings)
local Store = require(Util.Store)
local TerrainUtil = require(Util.TerrainUtil)

local Components = Plugin.Components
local App = require(Components.App)
local Outline = require(Components.Outline)
local StudioWidget = require(Components.StudioWidget)

local raycastParams = RaycastParams.new()
raycastParams.IgnoreWater = true

local PluginApp = React.PureComponent:extend('PluginApp')

function PluginApp:init()
  self.state = {
    guiEnabled = false,
  }

  -- This is a fix for a unintended side effect when undoing,
  -- where it will select the part and give it a outline.
  ChangeHistoryService.OnUndo:Connect(function(waypoint)
    if waypoint == 'PartToTerrain' then
      Selection:Set({})
    end
  end)

  self.plugin = self.props.plugin :: Plugin

  self.plugin.Deactivation:Connect(function()
    self:setState({ guiEnabled = false })
  end)

  -- TODO: Make PluginToolbar & PluginToolbarButton into a Roact component
  self.toolbar = self.plugin:CreateToolbar('Project Terra')

  self.button = self.toolbar:CreateButton(
    Localization('Plugin.Name') .. if Constants.IS_DEV_CHANNEL then '[DEV]' else '',
    Localization('Plugin.Desc'),
    Constants.PLUGIN_BUTTON_ICON
  )

  self.button.Click:Connect(function()
    if not self.state.guiEnabled then
      self.plugin:Activate(true)
      self:setState({ guiEnabled = true })
    else
      self.plugin:Deactivate()
    end
  end)

  ----------------------------------------
  -- Batch Conversion Helper
  ----------------------------------------
  self._isConverting = false

  local function convertSinglePart(part: BasePart)
    local shape, cframe, size = TerrainUtil:GetPartInfo(part)
    local material = Store:Get('Material')
    local preserveTerrain = Settings:Get('PreserveTerrain')

    local success = TerrainUtil:ConvertToTerrain(part, shape, material, cframe, size, preserveTerrain)
    if success then
      if Settings:Get('DeletePart') then
        part.Parent = nil
      end
    end
    return success
  end

  local function batchConvertParts(parts: { BasePart })
    if self._isConverting then
      warn("[PartToTerrain] A conversion is already in progress. Please wait.")
      return
    end
    self._isConverting = true

    task.spawn(function()
      local chRecording = ChangeHistoryService:TryBeginRecording('PartToTerrain')
      local totalParts = #parts
      local successCount = 0

      print(string.format("[PartToTerrain] Starting batch conversion of %d part(s)...", totalParts))

      for i, part in ipairs(parts) do
        print(string.format("[PartToTerrain] Converting chunk %d/%d: %s", i, totalParts, part.Name))
        local ok = convertSinglePart(part)
        if ok then
          successCount = successCount + 1
        else
          warn(string.format("[PartToTerrain] Failed to convert chunk %d/%d: %s", i, totalParts, part.Name))
        end
        -- Yield between parts to keep Studio responsive
        if i < totalParts then
          task.wait()
        end
      end

      print(string.format("[PartToTerrain] Batch conversion complete! %d/%d chunks converted successfully.", successCount, totalParts))

      if chRecording then
        if successCount > 0 then
          ChangeHistoryService:FinishRecording(chRecording, Enum.FinishRecordingOperation.Commit)
        else
          ChangeHistoryService:FinishRecording(chRecording, Enum.FinishRecordingOperation.Cancel)
        end
      end

      self._isConverting = false
    end)
  end

  ----------------------------------------
  -- Plugin Action: Convert All Selected MeshParts
  ----------------------------------------
  local convertSelectedAction = self.plugin:CreatePluginAction(
    'PartToTerrain_ConvertSelected',
    'Convert Selected to Terrain',
    'Converts all selected MeshParts to terrain sequentially.',
    '',
    true
  )

  self.ConvertSelectedActionConnection = convertSelectedAction.Triggered:Connect(function()
    if not self.state.guiEnabled then
      return
    end

    local selected = Selection:Get()
    local meshParts: { BasePart } = {}

    for _, obj in ipairs(selected) do
      if TerrainUtil:IsConvertibleToTerrain(obj) and obj:IsA('MeshPart') then
        table.insert(meshParts, obj :: BasePart)
      end
    end

    if #meshParts == 0 then
      warn("[PartToTerrain] No convertible MeshParts selected.")
      return
    end

    batchConvertParts(meshParts)
  end)

  ----------------------------------------
  -- Plugin Mouse
  ----------------------------------------
  self.pluginMouse = self.plugin:GetMouse()

  self.PluginMouseClickConnection = self.pluginMouse.Button1Down:Connect(function()
    -- Shift+Click: Convert all selected MeshParts (batch mode)
    if UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift) then
      local selected = Selection:Get()
      local meshParts: { BasePart } = {}

      for _, obj in ipairs(selected) do
        if TerrainUtil:IsConvertibleToTerrain(obj) and obj:IsA('MeshPart') then
          table.insert(meshParts, obj :: BasePart)
        end
      end

      if #meshParts > 0 then
        batchConvertParts(meshParts)
        return
      end
    end

    local cameraPos = workspace.CurrentCamera.CFrame.Position
    local dir = self.pluginMouse.UnitRay.Direction
    local RaycastResults = workspace:Raycast(cameraPos, dir * Constants.RAYCAST_LENGTH, raycastParams)

    if not RaycastResults then
      return
    end

    local obj = RaycastResults.Instance

    -- Adds in Terrain Editor's shortcut to select material.
    if UserInputService:IsKeyDown(Enum.KeyCode.LeftAlt) or UserInputService:IsKeyDown(Enum.KeyCode.RightAlt) then
      if obj:IsA('Terrain') then
        Store:Set('Material', RaycastResults.Material)
      end
      return
    end

    if not TerrainUtil:IsConvertibleToTerrain(obj) then
      return
    end

    if Settings:Get('IgnoreLockedParts') and obj.Locked then
      return
    end

    local part = obj :: BasePart
    batchConvertParts({ part })
  end)
end

function PluginApp:componentDidUpdate()
  self.button:SetActive(self.state.guiEnabled)

  if self.state.guiEnabled then
    task.spawn(function()
      -- stylua: ignore
      raycastParams.ExcludeInstances = Settings:Get('IgnoreInvisibleParts') and workspace:QueryDescendants('BasePart [Transparency = 1]') or {}
    end)
  end
end

function PluginApp:render()
  local state = self.state

  return React.createElement(StudioWidget, {
    plugin = self.plugin,
    Id = 'PartToTerrain',
    Title = Localization('Plugin.Name') .. if Constants.IS_DEV_CHANNEL then '[DEV]' else '',

    Enabled = state.guiEnabled,

    OverridePreviousState = true,
    FloatingSize = Vector2.new(250, 330),
    MinimumSize = Vector2.new(250, 300),

    onClose = function()
      self.plugin:Deactivate()
    end,
  }, {
    App = React.createElement(App),

    Outline = state.guiEnabled and React.createElement(Outline, {
      PluginMouse = self.pluginMouse,
      RaycastParams = raycastParams,
    }),
  })
end

function PluginApp:componentWillUnmount()
  self.toolbar:Destroy()
  self.button:Destroy()

  self.PluginMouseClickConnection:Disconnect()
  self.ConvertSelectedActionConnection:Disconnect()
end

return PluginApp
