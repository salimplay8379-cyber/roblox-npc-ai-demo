-- npc patrol and chase script
-- this script uses a simple state driven update loop
-- patrol chase and investigate each run through their own handler
-- chase movement switches between direct movement and pathfinding based on visibility and range
-- shared recovery logic also rebuilds movement if the npc gets stuck on map geometry

local Players = game:GetService("Players")
local PathfindingService = game:GetService("PathfindingService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local npcModel = script.Parent
local humanoid = npcModel:WaitForChild("Humanoid")
local root = npcModel:WaitForChild("HumanoidRootPart")
local head = npcModel:WaitForChild("Head")
local patrolFolder = Workspace.PatrolPoints

-- config values control detection movement attack timing and recovery behavior
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

-- runtime state keeps the current mode target path and timing data in one place
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

-- quick validity check used by the heartbeat loop
local function isAlive()
	return humanoid.Health > 0 and npcModel.Parent ~= nil
end

-- movement callbacks are replaced often so old connections need to be cleared
local function clearMoveConnection()
	if not state.MoveConnection then
		return
	end

	state.MoveConnection:Disconnect()
	state.MoveConnection = nil
end

-- resets any active path movement before switching behavior
local function stopCurrentPath()
	clearMoveConnection()
	state.CurrentPath = nil
	state.CurrentWaypoints = {}
	state.CurrentWaypointIndex = 1
	humanoid:Move(Vector3.zero)
end

-- returns the character humanoid and root for a valid living player
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

-- flattening the target position to the npc Y level keeps chase movement stable when players jump
local function getGroundTargetPosition(position)
	return Vector3.new(position.X, root.Position.Y, position.Z)
end

-- visibility is based on a raycast from the head so map geometry can block detection
local function hasLineOfSight(targetRoot)
	local origin = head.Position + config.SightOffset
	local direction = targetRoot.Position - origin

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = { npcModel }
	rayParams.IgnoreWater = true

	local result = Workspace:Raycast(origin, direction, rayParams)
	if not result then
		return true
	end

	return result.Instance:IsDescendantOf(targetRoot.Parent)
end

-- patrol and investigate both reuse this target search
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

-- builds a navigation path and returns nil if one cannot be computed
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

-- small obstacle jump check uses two raycasts to see if the top is clear
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

	local humanoidState = humanoid:GetState()
	if humanoidState == Enum.HumanoidStateType.Jumping
		or humanoidState == Enum.HumanoidStateType.Freefall then
		return
	end

	local moveDirection = humanoid.MoveDirection
	if moveDirection.Magnitude < 0.1 then
		return
	end

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = { npcModel }
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

	debugPrint("state", state.Mode, "->", newMode)
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

-- starts path following and advances through waypoints as MoveTo completes
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

-- patrol movement reuses the same path system and advances through patrol points in order
goToPatrolPoint = function()
	if #state.PatrolPoints == 0 then
		return
	end

	local patrolPoint = state.PatrolPoints[state.CurrentPatrolIndex]
	debugPrint("patrolling to", patrolPoint.Name)

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

-- patrol is the neutral state and clears chase and investigate data
startPatrol = function()
	stopCurrentPath()

	state.Target = nil
	state.LastSeenPosition = nil
	state.LastDirectTargetPosition = nil
	state.LastPathTargetPosition = nil
	state.InvestigateStartedAt = 0

	state.ChaseMode = "Path"
	state.LastChaseModeSwitch = 0

	humanoid.WalkSpeed = config.WalkSpeed
	setMode("Patrol")
	goToPatrolPoint()
end

-- entering chase stores a target and the most recent visible position
local function startChase(player)
	stopCurrentPath()

	state.Target = player
	state.InvestigateStartedAt = 0
	state.LastDirectTargetPosition = nil
	state.LastPathTargetPosition = nil
	state.ChaseMode = "Path"
	state.LastChaseModeSwitch = time()

	local _, _, targetRoot = getPlayerParts(player)
	state.LastSeenPosition = targetRoot and getGroundTargetPosition(targetRoot.Position) or nil

	humanoid.WalkSpeed = config.ChaseSpeed
	setMode("Chase")
	state.LastRepathTime = 0
	debugPrint("chasing", player.Name)
end

-- investigate sends the npc to the last visible position before it gives up
local function startInvestigate(lastPosition)
	if not config.UseInvestigateMode or not lastPosition then
		startPatrol()
		return
	end

	stopCurrentPath()

	state.Target = nil
	state.InvestigateStartedAt = 0
	state.LastDirectTargetPosition = nil
	state.LastPathTargetPosition = nil
	state.ChaseMode = "Path"

	humanoid.WalkSpeed = config.WalkSpeed
	setMode("Investigate")
	startPathChase(lastPosition)
end

local function canAttack()
	return (time() - state.LastAttackTime) >= config.AttackCooldown
end

-- attack is split out so chase logic can focus on movement and state transitions
local function attackTarget()
	if not state.Target then
		return
	end

	local character, targetHumanoid, targetRoot = getPlayerParts(state.Target)
	if not character or not targetHumanoid or not targetRoot then
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
	debugPrint("attacked", state.Target.Name, "for", config.Damage)
end

-- patrol and investigate can both pick up a fresh target if the npc sees one
local function checkForTarget()
	local visiblePlayer = findClosestVisiblePlayer()
	if visiblePlayer then
		startChase(visiblePlayer)
	end
end

-- direct chase is used up close so movement feels more responsive than constant repathing
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

	if state.LastDirectTargetPosition then
		local moveDelta = (predictedPosition - state.LastDirectTargetPosition).Magnitude
		if moveDelta < 1.5 then
			return
		end
	end

	state.LastDirectTargetPosition = predictedPosition

	if (predictedPosition - root.Position).Magnitude > config.DirectMoveMinDist then
		humanoid:MoveTo(predictedPosition)
	end
end

-- path chase rebuilds movement less often and is used when the target is farther away or hidden
local function updatePathChase(targetGroundPosition)
	if time() - state.LastRepathTime < config.RepathInterval then
		return
	end

	local chasePosition = state.LastSeenPosition or targetGroundPosition

	if state.LastPathTargetPosition then
		local moveDelta = (chasePosition - state.LastPathTargetPosition).Magnitude
		if moveDelta < config.RepathMinDist then
			return
		end
	end

	if state.CurrentWaypoints and #state.CurrentWaypoints > 0 then
		local currentGoal = state.CurrentWaypoints[#state.CurrentWaypoints].Position
		if (currentGoal - chasePosition).Magnitude < config.RepathMinDist then
			return
		end
	end

	state.LastRepathTime = time()
	state.LastPathTargetPosition = chasePosition
	startPathChase(chasePosition)
end

local function loseTargetToInvestigate()
	if state.LastSeenPosition then
		startInvestigate(state.LastSeenPosition)
	else
		startPatrol()
	end
end

local function switchToDirectChase()
	if state.ChaseMode == "Direct" then
		return
	end

	if time() - state.LastChaseModeSwitch < config.ChaseSwitchCooldown then
		return
	end

	state.ChaseMode = "Direct"
	state.LastChaseModeSwitch = time()
	stopCurrentPath()
	state.LastDirectTargetPosition = nil
end

local function switchToPathChase()
	if state.ChaseMode == "Path" then
		return
	end

	if time() - state.LastChaseModeSwitch < config.ChaseSwitchCooldown then
		return
	end

	state.ChaseMode = "Path"
	state.LastChaseModeSwitch = time()
	stopCurrentPath()
	state.LastPathTargetPosition = nil
end

-- chase validates the target attacks when in range and decides how movement should be updated
local function updateChase()
	if not state.Target then
		loseTargetToInvestigate()
		return
	end

	local character, _, targetRoot = getPlayerParts(state.Target)
	if not character or not targetRoot then
		debugPrint("lost target because character is invalid")
		loseTargetToInvestigate()
		return
	end

	local targetGroundPosition = getGroundTargetPosition(targetRoot.Position)
	local distance = (root.Position - targetGroundPosition).Magnitude
	if distance > config.LoseRange then
		debugPrint("lost target due to distance")
		loseTargetToInvestigate()
		return
	end

	attackTarget()

	local hasSight = hasLineOfSight(targetRoot)
	local wantsDirectChase = hasSight and distance < config.DirectChaseRange
	if hasSight then
		state.LastSeenPosition = targetGroundPosition
	end

	if wantsDirectChase then
		switchToDirectChase()
	else
		switchToPathChase()
	end

	if state.ChaseMode == "Direct" then
		updateDirectChase(targetRoot, targetGroundPosition)
		return
	end

	updatePathChase(targetGroundPosition)
end

-- investigate waits briefly at the last seen position before returning to patrol
local function updateInvestigate()
	if not state.LastSeenPosition then
		startPatrol()
		return
	end

	local distanceToInvestigatePoint = (root.Position - state.LastSeenPosition).Magnitude
	if distanceToInvestigatePoint > config.InvestigateArriveDistance then
		return
	end

	if state.InvestigateStartedAt == 0 then
		state.InvestigateStartedAt = time()
		return
	end

	if time() - state.InvestigateStartedAt < config.InvestigateWaitTime then
		return
	end

	state.InvestigateStartedAt = 0
	state.LastSeenPosition = nil
	startPatrol()
end

local function recoverChaseMovement()
	local character, _, targetRoot = getPlayerParts(state.Target)
	if not character or not targetRoot then
		return
	end

	stopCurrentPath()

	local targetGroundPosition = getGroundTargetPosition(targetRoot.Position)
	local hasSight = hasLineOfSight(targetRoot)
	local distance = (root.Position - targetGroundPosition).Magnitude

	if hasSight and distance < config.DirectChaseRange then
		state.ChaseMode = "Direct"
		state.LastChaseModeSwitch = time()
		state.LastDirectTargetPosition = nil
		humanoid:MoveTo(targetGroundPosition)
		return
	end

	state.ChaseMode = "Path"
	state.LastChaseModeSwitch = time()
	state.LastPathTargetPosition = nil
	startPathChase(state.LastSeenPosition or targetGroundPosition)
end

local function recoverInvestigateMovement()
	if not state.LastSeenPosition then
		return
	end

	stopCurrentPath()
	startPathChase(state.LastSeenPosition)
end

local function recoverPatrolMovement()
	if #state.PatrolPoints == 0 then
		return
	end

	stopCurrentPath()
	goToPatrolPoint()
end

-- if the npc stops moving for too long this rebuilds whatever movement mode is active
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

	debugPrint("npc seems stuck, recalculating")

	if state.Mode == "Chase" and state.Target then
		recoverChaseMovement()
	elseif state.Mode == "Investigate" then
		recoverInvestigateMovement()
	elseif state.Mode == "Patrol" then
		recoverPatrolMovement()
	end

	state.StuckStartTime = nil
	state.LastPosition = root.Position
end

-- state handlers keep the heartbeat loop flatter and make the state flow easier to follow
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

-- patrol points are collected once and sorted by name so the route stays predictable
for _, point in ipairs(patrolFolder:GetChildren()) do
	if point:IsA("BasePart") then
		table.insert(state.PatrolPoints, point)
	end
end

table.sort(state.PatrolPoints, function(a, b)
	return a.Name < b.Name
end)

startPatrol()

-- heartbeat runs the active state handler and shared movement helpers every frame
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

-- cleanup makes sure old movement callbacks are not left running after death
humanoid.Died:Connect(function()
	state.Destroyed = true
	clearMoveConnection()
end)
