-- npc patrol and chase script

local Players = game:GetService("Players")
local PathfindingService = game:GetService("PathfindingService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local npcModel = script.Parent
local humanoid = npcModel:WaitForChild("Humanoid")
local root = npcModel:WaitForChild("HumanoidRootPart")
local head = npcModel:WaitForChild("Head")
local patrolFolder = Workspace.PatrolPoints

local config = {
	DetectionRange = 60,
	AttackRange = 5,
	LoseRange = 100,
	PatrolWaitTime = 1.5,

	-- lower felt too twitchy because it kept rebuilding paths
	RepathInterval = 0.8,

	AttackCooldown = 1.2,
	Damage = 12,
	WalkSpeed = 10,
	ChaseSpeed = 16,
	SightOffset = Vector3.new(0, 2, 0),
	StuckThreshold = 1.5,
	StuckTime = 1.5,
	Debug = false,

	AutoJumpEnabled = true,
	AutoJumpDist = 5,
	AutoJumpHeight = 2.5,
	AutoJumpCooldown = 0.25,

	-- close range felt better with direct movement instead of full pathing
	DirectChaseRange = 10,
	ChaseSwitchCooldown = 0.6,
	DirectMoveRefresh = 0.35,
	DirectPrediction = 0.12,
	DirectMoveMinDist = 2,
	RepathMinDist = 3,

	-- if the npc loses the player it checks the last seen spot first
	-- this felt better than snapping straight back into patrol
	UseInvestigateMode = true,
	InvestigateWaitTime = 1.5,
}

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

	Investigating = false,
	InvestigateStartedAt = 0,

	Destroyed = false,
}

local function debugPrint(...)
	if config.Debug then
		print("[npc]", ...)
	end
end

local function isAlive()
	return humanoid.Health > 0 and npcModel.Parent ~= nil
end

local function clearMoveConnection()
	if state.MoveConnection then
		state.MoveConnection:Disconnect()
		state.MoveConnection = nil
	end
end

local function stopCurrentPath()
	clearMoveConnection()
	state.CurrentPath = nil
	state.CurrentWaypoints = {}
	state.CurrentWaypointIndex = 1
	humanoid:Move(Vector3.zero)
end

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

local function getGroundTargetPosition(position)
	-- keeping the npc on its current Y stops weird chase behavior when players jump
	return Vector3.new(position.X, root.Position.Y, position.Z)
end

local function hasLineOfSight(targetRoot)
	-- cast from the head so walls block vision properly
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

local function findClosestVisiblePlayer()
	local closestPlayer = nil
	local closestDistance = config.DetectionRange

	for _, player in ipairs(Players:GetPlayers()) do
		local character, _, targetRoot = getPlayerParts(player)

		if character and targetRoot then
			local distance = (root.Position - targetRoot.Position).Magnitude

			if distance <= closestDistance and hasLineOfSight(targetRoot) then
				closestDistance = distance
				closestPlayer = player
			end
		end
	end

	return closestPlayer
end

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

local function tryAutoJump()
	if not config.AutoJumpEnabled then
		return
	end

	if time() - state.LastJumpTime < config.AutoJumpCooldown then
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
		if state.Destroyed or state.Mode ~= "Chase" and state.Mode ~= "Investigate" or state.ChaseMode ~= "Path" and state.Mode ~= "Investigate" then
			return
		end

		if reached then
			state.CurrentWaypointIndex += 1
			if state.CurrentWaypointIndex <= #state.CurrentWaypoints then
				moveToNextWaypoint()
			end
		end
	end)
end

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

		if reached then
			state.CurrentWaypointIndex += 1

			if state.CurrentWaypointIndex <= #state.CurrentWaypoints then
				moveToNextWaypoint()
			else
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
			end
		end
	end)
end

startPatrol = function()
	stopCurrentPath()

	state.Target = nil
	state.LastSeenPosition = nil
	state.LastDirectTargetPosition = nil
	state.LastPathTargetPosition = nil
	state.Investigating = false
	state.InvestigateStartedAt = 0

	state.ChaseMode = "Path"
	state.LastChaseModeSwitch = 0

	humanoid.WalkSpeed = config.WalkSpeed
	setMode("Patrol")
	goToPatrolPoint()
end

local function startChase(player)
	stopCurrentPath()

	state.Target = player
	state.Investigating = false
	state.InvestigateStartedAt = 0
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
	debugPrint("chasing", player.Name)
end

local function startInvestigate(lastPosition)
	if not config.UseInvestigateMode or not lastPosition then
		startPatrol()
		return
	end

	stopCurrentPath()

	state.Target = nil
	state.Investigating = true
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

local function attackTarget()
	if not state.Target then
		return
	end

	local character, targetHumanoid, targetRoot = getPlayerParts(state.Target)
	if not character or not targetHumanoid or not targetRoot then
		return
	end

	if (root.Position - targetRoot.Position).Magnitude <= config.AttackRange and canAttack() then
		state.LastAttackTime = time()
		targetHumanoid:TakeDamage(config.Damage)
		debugPrint("attacked", state.Target.Name, "for", config.Damage)
	end
end

local function checkForTarget()
	if state.Mode ~= "Patrol" and state.Mode ~= "Investigate" then
		return
	end

	local visiblePlayer = findClosestVisiblePlayer()
	if visiblePlayer then
		startChase(visiblePlayer)
	end
end

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
		local moveDelta = (predictedPosition - state.LastDirectTargetPosition).Magnitude
		movedEnough = moveDelta >= 1.5
	end

	if not movedEnough then
		return
	end

	state.LastDirectTargetPosition = predictedPosition

	if (predictedPosition - root.Position).Magnitude > config.DirectMoveMinDist then
		humanoid:MoveTo(predictedPosition)
	end
end

local function updatePathChase(targetGroundPosition)
	if time() - state.LastRepathTime < config.RepathInterval then
		return
	end

	local chasePosition = state.LastSeenPosition or targetGroundPosition

	local movedEnough = true
	if state.LastPathTargetPosition then
		local moveDelta = (chasePosition - state.LastPathTargetPosition).Magnitude
		movedEnough = moveDelta >= config.RepathMinDist
	end

	if not movedEnough then
		return
	end

	state.LastRepathTime = time()
	state.LastPathTargetPosition = chasePosition
	startPathChase(chasePosition)
end

local function updateChase()
	if not state.Target then
		if state.LastSeenPosition then
			startInvestigate(state.LastSeenPosition)
		else
			startPatrol()
		end
		return
	end

	local character, _, targetRoot = getPlayerParts(state.Target)
	if not character or not targetRoot then
		debugPrint("lost target because character is invalid")

		if state.LastSeenPosition then
			startInvestigate(state.LastSeenPosition)
		else
			startPatrol()
		end
		return
	end

	local targetGroundPosition = getGroundTargetPosition(targetRoot.Position)
	local distance = (root.Position - targetGroundPosition).Magnitude

	if distance > config.LoseRange then
		debugPrint("lost target due to distance")

		if state.LastSeenPosition then
			startInvestigate(state.LastSeenPosition)
		else
			startPatrol()
		end
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

local function checkIfStuck()
	-- if it sits almost still too long it probably got hung up on something
	local movementDelta = (root.Position - state.LastPosition).Magnitude

	if movementDelta < config.StuckThreshold then
		if not state.StuckStartTime then
			state.StuckStartTime = time()
		elseif time() - state.StuckStartTime >= config.StuckTime then
			debugPrint("npc seems stuck, recalculating")

			if state.Mode == "Chase" and state.Target then
				local character, _, targetRoot = getPlayerParts(state.Target)
				if character and targetRoot then
					stopCurrentPath()

					local targetGroundPosition = getGroundTargetPosition(targetRoot.Position)
					local hasSight = hasLineOfSight(targetRoot)
					local distance = (root.Position - targetGroundPosition).Magnitude

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
			elseif state.Mode == "Investigate" and state.LastSeenPosition then
				stopCurrentPath()
				startPathChase(state.LastSeenPosition)
			elseif state.Mode == "Patrol" and #state.PatrolPoints > 0 then
				stopCurrentPath()
				goToPatrolPoint()
			end

			state.StuckStartTime = nil
		end
	else
		state.StuckStartTime = nil
	end

	state.LastPosition = root.Position
end

-- I randomized patrol order instead of sorting by name
-- makes movement feel less scripted and repetitive
for _, point in ipairs(patrolFolder:GetChildren()) do
	if point:IsA("BasePart") then
		table.insert(state.PatrolPoints, point)
	end
end

-- shuffle patrol points so the npc path is less predictable
for i = #state.PatrolPoints, 2, -1 do
	local j = math.random(1, i)
	state.PatrolPoints[i], state.PatrolPoints[j] = state.PatrolPoints[j], state.PatrolPoints[i]
end

startPatrol()

local heartbeatConnection
heartbeatConnection = RunService.Heartbeat:Connect(function()
	if not isAlive() then
		state.Destroyed = true
		clearMoveConnection()
		heartbeatConnection:Disconnect()
		return
	end

	checkForTarget()

	if state.Mode == "Chase" then
		updateChase()
	end

	if state.Mode == "Investigate" and state.LastSeenPosition then
		if (root.Position - state.LastSeenPosition).Magnitude <= 4 then
			if state.InvestigateStartedAt == 0 then
				state.InvestigateStartedAt = time()
			elseif time() - state.InvestigateStartedAt >= config.InvestigateWaitTime then
				state.Investigating = false
				state.InvestigateStartedAt = 0
				state.LastSeenPosition = nil
				startPatrol()
			end
		end
	end

	tryAutoJump()
	checkIfStuck()
end)

humanoid.Died:Connect(function()
	state.Destroyed = true
	clearMoveConnection()
end)
