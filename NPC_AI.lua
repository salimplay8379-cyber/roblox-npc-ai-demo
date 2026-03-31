-- NPC Patrol And Chase Controller.
-- This script acts as a state-driven AI controller for a single NPC.
-- The NPC can patrol, chase visible players, and investigate the player’s last known position.
-- The main update loop selects the active state handler, then runs shared support systems such as jumping and stuck recovery.
-- This separation keeps behavior logic isolated from reusable movement systems.

local Players = game:GetService("Players")
local PathfindingService = game:GetService("PathfindingService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local npcModel = script.Parent
local humanoid = npcModel:WaitForChild("Humanoid")
local root = npcModel:WaitForChild("HumanoidRootPart")
local head = npcModel:WaitForChild("Head")
local patrolFolder = Workspace.PatrolPoints

-- Configuration values.
-- These values control detection distance, movement timing, attack pacing, and recovery behavior.
-- Keeping them centralized makes balancing and tuning easier.
local config = {
	DetectionRange = 80,
	AttackRange = 5,
	LoseRange = 100,
	PatrolWaitTime = 1.5,
	RepathInterval = 0.4,
	AttackCooldown = 1.2,
	Damage = 15,
	WalkSpeed = 10,
	ChaseSpeed = 16,
	SightOffset = Vector3.new(0, 2, 0),
	StuckThreshold = 1,
	StuckTime = 2,
	Debug = false,

	AutoJumpEnabled = true,
	AutoJumpDist = 5,
	AutoJumpHeight = 2.5,
	AutoJumpCooldown = 0.4,

	DirectChaseRange = 0,
	ChaseSwitchCooldown = 0.6,
	DirectMoveRefresh = 0.35,
	DirectPrediction = 0.12,
	DirectMoveMinDist = 2,
	RepathMinDist = 2,

	UseInvestigateMode = true,
	InvestigateWaitTime = 2,
	InvestigateArriveDistance = 4,
}

-- Runtime state container.
-- Stores all values that change while the NPC is active.
local state = {
	Mode = "Patrol",
	Target = nil,

	LastAttackTime = 0,
	LastRepathTime = 0,
	LastJumpTime = 0,

	CurrentPatrolIndex = 1,
	PatrolPoints = {},

	CurrentPath = nil,
	CurrentWaypoints = {},
	CurrentWaypointIndex = 1,
	MoveConnection = nil,

	StuckStartTime = nil,
	LastPosition = root.Position,
	LastSeenPosition = nil,

	ChaseMode = "Path",
	LastChaseModeSwitch = 0,
	LastDirectTargetPosition = nil,
	LastPathTargetPosition = nil,

	InvestigateStartedAt = 0,
	Destroyed = false,
}

local function debugPrint(...)
	if config.Debug then
		print("[npc]", ...)
	end
end

-- Safety validation.
local function isAlive()
	return humanoid.Health > 0 and npcModel.Parent ~= nil
end

-- Removes any active movement callback.
local function clearMoveConnection()
	if not state.MoveConnection then
		return
	end

	state.MoveConnection:Disconnect()
	state.MoveConnection = nil
end

-- Clears all current path data before a new movement plan begins.
local function stopCurrentPath()
	clearMoveConnection()
	state.CurrentPath = nil
	state.CurrentWaypoints = {}
	state.CurrentWaypointIndex = 1
	humanoid:Move(Vector3.zero)
end

-- Returns the required character parts for NPC interaction.
local function getPlayerParts(player)
	if not player then
		return nil
	end

	local character = player.Character
	if not character then
		return nil
	end

	local targetHumanoid = character:FindFirstChildOfClass("Humanoid")
	local targetRoot = character:FindFirstChild("HumanoidRootPart")

	if not targetHumanoid or not targetRoot then
		return nil
	end

	if targetHumanoid.Health <= 0 then
		return nil
	end

	return character, targetHumanoid, targetRoot
end

-- Converts a target position into horizontal chase space.
local function getGroundTargetPosition(position)
	return Vector3.new(position.X, root.Position.Y, position.Z)
end

-- Checks whether the NPC can visually see the target.
local function hasLineOfSight(targetRoot)
	local origin = head.Position + config.SightOffset
	local direction = targetRoot.Position - origin

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = {npcModel}
	rayParams.IgnoreWater = true

	local result = Workspace:Raycast(origin, direction, rayParams)
	if not result then
		return true
	end

	return result.Instance:IsDescendantOf(targetRoot.Parent)
end

-- Finds the closest valid visible player.
local function findClosestVisiblePlayer()
	local closestPlayer = nil
	local closestDistance = config.DetectionRange

	for _, player in ipairs(Players:GetPlayers()) do
		local character, _, targetRoot = getPlayerParts(player)
		if not character or not targetRoot then
			continue
		end

		local distance = (root.Position - targetRoot.Position).Magnitude
		if distance > closestDistance then
			continue
		end

		if not hasLineOfSight(targetRoot) then
			continue
		end

		closestDistance = distance
		closestPlayer = player
	end

	return closestPlayer
end

-- Builds a path to the requested destination.
local function buildPath(destination)
	local path = PathfindingService:CreatePath({
		AgentRadius = 1.5,
		AgentHeight = 5,
		AgentCanJump = true,
		AgentJumpHeight = 7,
		AgentMaxSlope = 45,
	})

	local ok, err = pcall(function()
		path:ComputeAsync(root.Position, destination)
	end)

	if not ok then
		debugPrint("path computation failed", err)
		return nil
	end

	if path.Status ~= Enum.PathStatus.Success then
		debugPrint("path failed with status", path.Status.Name)
		return nil
	end

	return path
end

local function usePath(path)
	state.CurrentPath = path
	state.CurrentWaypoints = path:GetWaypoints()
	state.CurrentWaypointIndex = 1
end

local function moveToNextWaypoint()
	if #state.CurrentWaypoints == 0 then
		return
	end

	if state.CurrentWaypointIndex > #state.CurrentWaypoints then
		return
	end

	local waypoint = state.CurrentWaypoints[state.CurrentWaypointIndex]
	if waypoint.Action == Enum.PathWaypointAction.Jump then
		humanoid.Jump = true
	end

	humanoid:MoveTo(waypoint.Position)
end

-- Auto-jump support for small obstacles.
local function tryAutoJump()
	if not config.AutoJumpEnabled then
		return
	end

	if time() - state.LastJumpTime < config.AutoJumpCooldown then
		return
	end

	if humanoid.FloorMaterial == Enum.Material.Air then
		return
	end

	local moveDirection = humanoid.MoveDirection
	if moveDirection.Magnitude < 0.1 then
		return
	end

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = {npcModel}
	rayParams.IgnoreWater = true

	local forward = moveDirection.Unit * config.AutoJumpDist
	local lowOrigin = root.Position + Vector3.new(0, 1, 0)
	local lowHit = Workspace:Raycast(lowOrigin, forward, rayParams)
	if not lowHit then
		return
	end

	local highOrigin = root.Position + Vector3.new(0, config.AutoJumpHeight, 0)
	local highHit = Workspace:Raycast(highOrigin, forward, rayParams)
	if highHit then
		return
	end

	humanoid.Jump = true
	state.LastJumpTime = time()
end

local function setMode(newMode)
	if state.Mode == newMode then
		return
	end

	state.Mode = newMode
end

local function isPathMovementMode()
	if state.Mode == "Investigate" then
		return true
	end

	return state.Mode == "Chase" and state.ChaseMode == "Path"
end

local goToPatrolPoint
local startPatrol
local startPathChase

startPathChase = function(destination)
	local path = buildPath(destination)
	if not path then
		return
	end

	usePath(path)
	clearMoveConnection()
	moveToNextWaypoint()

	state.MoveConnection = humanoid.MoveToFinished:Connect(function(reached)
		if state.Destroyed then
			return
		end

		if not isPathMovementMode() then
			return
		end

		if not reached then
			return
		end

		state.CurrentWaypointIndex += 1
		if state.CurrentWaypointIndex <= #state.CurrentWaypoints then
			moveToNextWaypoint()
		end
	end)
end
goToPatrolPoint = function()
	if #state.PatrolPoints == 0 then
		return
	end

	local patrolPoint = state.PatrolPoints[state.CurrentPatrolIndex]
	local path = buildPath(patrolPoint.Position)
	if not path then
		return
	end

	usePath(path)
	clearMoveConnection()
	moveToNextWaypoint()

	state.MoveConnection = humanoid.MoveToFinished:Connect(function(reached)
		if state.Destroyed or state.Mode ~= "Patrol" then
			return
		end

		if not reached then
			return
		end

		state.CurrentWaypointIndex += 1
		if state.CurrentWaypointIndex <= #state.CurrentWaypoints then
			moveToNextWaypoint()
			return
		end

		task.delay(config.PatrolWaitTime, function()
			if state.Destroyed or state.Mode ~= "Patrol" then
				return
			end

			state.CurrentPatrolIndex += 1
			if state.CurrentPatrolIndex > #state.PatrolPoints then
				state.CurrentPatrolIndex = 1
			end

			goToPatrolPoint()
		end)
	end)
end

-- Starts Patrol mode.
-- Resets chase and investigate tracking values,
-- restores patrol speed,
-- and begins movement toward the current patrol point.
startPatrol = function()
	stopCurrentPath()
	state.Target = nil
	state.LastSeenPosition = nil
	state.LastDirectTargetPosition = nil
	state.LastPathTargetPosition = nil
	state.InvestigateStartedAt = 0
	state.ChaseMode = "Path"
	humanoid.WalkSpeed = config.WalkSpeed
	setMode("Patrol")
	goToPatrolPoint()
end

-- Starts Chase mode.
-- Stores the active target,
-- refreshes chase movement tracking,
-- and saves the last visible position.
local function startChase(player)
	stopCurrentPath()
	state.Target = player
	state.LastDirectTargetPosition = nil
	state.LastPathTargetPosition = nil
	state.ChaseMode = "Path"
	state.LastChaseModeSwitch = time()

	local _, _, targetRoot = getPlayerParts(player)
	if targetRoot then
		state.LastSeenPosition = getGroundTargetPosition(targetRoot.Position)
	else
		state.LastSeenPosition = nil
	end

	humanoid.WalkSpeed = config.ChaseSpeed
	setMode("Chase")
	state.LastRepathTime = 0
end

-- Starts Investigate mode.
-- Moves the NPC toward the last seen player position,
-- then returns to Patrol if no target is reacquired.
local function startInvestigate()
	if not config.UseInvestigateMode then
		startPatrol()
		return
	end

	if not state.LastSeenPosition then
		startPatrol()
		return
	end

	stopCurrentPath()
	humanoid.WalkSpeed = config.WalkSpeed
	setMode("Investigate")
	state.InvestigateStartedAt = time()
	startPathChase(state.LastSeenPosition)
end

-- Checks whether the NPC can attack again.
local function canAttack()
	return (time() - state.LastAttackTime) >= config.AttackCooldown
end

-- Damages the current target if it is close enough.
local function attackTarget()
	if not state.Target then
		return
	end

	local _, targetHumanoid, targetRoot = getPlayerParts(state.Target)
	if not targetHumanoid or not targetRoot then
		return
	end

	if (root.Position - targetRoot.Position).Magnitude > config.AttackRange then
		return
	end

	if not canAttack() then
		return
	end

	state.LastAttackTime = time()
	targetHumanoid:TakeDamage(config.Damage)
end

-- Checks whether Patrol or Investigate should enter Chase.
local function checkForTarget()
	if state.Mode == "Chase" then
		return
	end

	local visiblePlayer = findClosestVisiblePlayer()
	if visiblePlayer then
		startChase(visiblePlayer)
	end
end

-- Handles direct close-range movement.
-- This skips pathfinding for nearby visible targets.
local function updateDirectChase(targetRoot, targetGroundPosition)
	if time() - state.LastRepathTime < config.DirectMoveRefresh then
		return
	end

	state.LastRepathTime = time()

	local predictedPosition = targetGroundPosition
	local targetVelocity = targetRoot.AssemblyLinearVelocity
	local flatVelocity = Vector3.new(targetVelocity.X, 0, targetVelocity.Z)

	if flatVelocity.Magnitude > 1 then
		predictedPosition += flatVelocity * config.DirectPrediction
	end

	local movedEnough = true
	if state.LastDirectTargetPosition then
		local delta = (predictedPosition - state.LastDirectTargetPosition).Magnitude
		movedEnough = delta >= 1.5
	end

	if not movedEnough then
		return
	end

	state.LastDirectTargetPosition = predictedPosition

	if (predictedPosition - root.Position).Magnitude > config.DirectMoveMinDist then
		humanoid:MoveTo(predictedPosition)
	end
end

-- Handles long-range path chase movement.
local function updatePathChase(targetGroundPosition)
	if time() - state.LastRepathTime < config.RepathInterval then
		return
	end

	local chasePosition = state.LastSeenPosition or targetGroundPosition

	local movedEnough = true
	if state.LastPathTargetPosition then
		local delta = (chasePosition - state.LastPathTargetPosition).Magnitude
		movedEnough = delta >= config.RepathMinDist
	end

	if not movedEnough then
		return
	end

	state.LastRepathTime = time()
	state.LastPathTargetPosition = chasePosition
	startPathChase(chasePosition)
end

-- Main Chase update.
-- Validates target state,
-- updates last seen position,
-- attacks when close,
-- and chooses direct or path chase behavior.
local function updateChase()
	if not state.Target then
		startPatrol()
		return
	end

	local character, _, targetRoot = getPlayerParts(state.Target)
	if not character or not targetRoot then
		startInvestigate()
		return
	end

	local targetGroundPosition = getGroundTargetPosition(targetRoot.Position)
	local distance = (root.Position - targetGroundPosition).Magnitude

	if distance > config.LoseRange then
		startInvestigate()
		return
	end

	attackTarget()

	local hasSight = hasLineOfSight(targetRoot)
	local wantsDirectChase = hasSight and distance < config.DirectChaseRange

	if hasSight then
		state.LastSeenPosition = targetGroundPosition
	end

	if wantsDirectChase and state.ChaseMode ~= "Direct" then
		if time() - state.LastChaseModeSwitch >= config.ChaseSwitchCooldown then
			state.ChaseMode = "Direct"
			state.LastChaseModeSwitch = time()
			stopCurrentPath()
			state.LastDirectTargetPosition = nil
		end
	elseif not wantsDirectChase and state.ChaseMode ~= "Path" then
		if time() - state.LastChaseModeSwitch >= config.ChaseSwitchCooldown then
			state.ChaseMode = "Path"
			state.LastChaseModeSwitch = time()
			stopCurrentPath()
			state.LastPathTargetPosition = nil
		end
	end

	if state.ChaseMode == "Direct" then
		updateDirectChase(targetRoot, targetGroundPosition)
	else
		updatePathChase(targetGroundPosition)
	end
end
-- Updates Investigate mode.
-- Once the NPC reaches the last seen position,
-- it waits briefly before returning to Patrol.
local function updateInvestigate()
	if not state.LastSeenPosition then
		startPatrol()
		return
	end

	local distance = (root.Position - state.LastSeenPosition).Magnitude
	if distance > config.InvestigateArriveDistance then
		return
	end

	if time() - state.InvestigateStartedAt < config.InvestigateWaitTime then
		return
	end

	state.LastSeenPosition = nil
	startPatrol()
end

-- Rebuilds Chase movement after a stuck event.
local function recoverChaseMovement()
	if not state.Target then
		startPatrol()
		return
	end

	local character, _, targetRoot = getPlayerParts(state.Target)
	if not character or not targetRoot then
		startInvestigate()
		return
	end

	local targetGroundPosition = getGroundTargetPosition(targetRoot.Position)
	local hasSight = hasLineOfSight(targetRoot)
	local distance = (root.Position - targetGroundPosition).Magnitude

	stopCurrentPath()

	if hasSight and distance < config.DirectChaseRange then
		state.ChaseMode = "Direct"
		state.LastChaseModeSwitch = time()
		state.LastDirectTargetPosition = nil
		humanoid:MoveTo(targetGroundPosition)
	else
		state.ChaseMode = "Path"
		state.LastChaseModeSwitch = time()
		state.LastPathTargetPosition = nil
		local chasePosition = state.LastSeenPosition or targetGroundPosition
		startPathChase(chasePosition)
	end
end

-- Rebuilds Patrol movement after a stuck event.
local function recoverPatrolMovement()
	stopCurrentPath()
	goToPatrolPoint()
end

-- Rebuilds Investigate movement after a stuck event.
local function recoverInvestigateMovement()
	if not state.LastSeenPosition then
		startPatrol()
		return
	end

	stopCurrentPath()
	startPathChase(state.LastSeenPosition)
end

-- Stuck detection and recovery.
-- If movement stays below the threshold for too long,
-- the NPC rebuilds movement based on the active state.
local function checkIfStuck()
	local movementDelta = (root.Position - state.LastPosition).Magnitude

	if movementDelta >= config.StuckThreshold then
		state.StuckStartTime = nil
		state.LastPosition = root.Position
		return
	end

	if not state.StuckStartTime then
		state.StuckStartTime = time()
		state.LastPosition = root.Position
		return
	end

	if time() - state.StuckStartTime < config.StuckTime then
		state.LastPosition = root.Position
		return
	end

	if state.Mode == "Chase" then
		recoverChaseMovement()
	elseif state.Mode == "Investigate" then
		recoverInvestigateMovement()
	elseif state.Mode == "Patrol" then
		recoverPatrolMovement()
	end

	state.StuckStartTime = nil
	state.LastPosition = root.Position
end

-- State handlers define the top-level logic for each AI mode.
local StateHandlers = {}

StateHandlers.Patrol = function()
	checkForTarget()
end

StateHandlers.Chase = function()
	updateChase()
end

StateHandlers.Investigate = function()
	checkForTarget()
	updateInvestigate()
end

-- Patrol points are loaded once on startup.
-- Sorting keeps the route predictable.
for _, point in ipairs(patrolFolder:GetChildren()) do
	if point:IsA("BasePart") then
		table.insert(state.PatrolPoints, point)
	end
end

table.sort(state.PatrolPoints, function(a, b)
	return a.Name < b.Name
end)

startPatrol()

-- Main update loop.
-- Runs the active state handler,
-- then applies shared movement support systems.
local heartbeatConnection
heartbeatConnection = RunService.Heartbeat:Connect(function()
	if not isAlive() then
		state.Destroyed = true
		clearMoveConnection()
		heartbeatConnection:Disconnect()
		return
	end

	local handler = StateHandlers[state.Mode]
	if handler then
		handler()
	end

	tryAutoJump()
	checkIfStuck()
end)

-- Cleanup on NPC death.
humanoid.Died:Connect(function()
	state.Destroyed = true
	clearMoveConnection()
end)
