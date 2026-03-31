-- npc patrol and chase script
-- this script runs as a state driven ai controller for one npc
-- the npc can patrol chase a visible player and investigate the last seen position
-- the main loop selects the current state handler and then runs shared movement support systems
-- this layout keeps state logic separated from reusable helpers like pathing jumping and recovery

local Players = game:GetService("Players")
local PathfindingService = game:GetService("PathfindingService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local npcModel = script.Parent
local humanoid = npcModel:WaitForChild("Humanoid")
local root = npcModel:WaitForChild("HumanoidRootPart")
local head = npcModel:WaitForChild("Head")
local patrolFolder = Workspace.PatrolPoints

-- config values tune how far the npc can detect targets
-- how often movement updates happen
-- how quickly attacks can fire
-- and how recovery systems respond when movement fails
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

-- runtime state stores the live data that changes while the npc is running
-- this includes the current state target movement path timers and last seen information
-- keeping this data in one table makes it easier to manage transitions between behaviors
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

-- this is a quick safety check used by the main loop
-- once the humanoid is dead or the model is removed the rest of the ai should stop running
local function isAlive()
	return humanoid.Health > 0 and npcModel.Parent ~= nil
end

-- movement callbacks are recreated whenever the npc switches paths or states
-- this helper clears the old callback so only one movement listener stays active at a time
local function clearMoveConnection()
	if not state.MoveConnection then
		return
	end

	state.MoveConnection:Disconnect()
	state.MoveConnection = nil
end

-- this fully clears the current path state before a new movement plan begins
-- it is used when switching between patrol chase investigate and recovery behaviors
local function stopCurrentPath()
	clearMoveConnection()
	state.CurrentPath = nil
	state.CurrentWaypoints = {}
	state.CurrentWaypointIndex = 1
	humanoid:Move(Vector3.zero)
end

-- this returns the main character parts needed by the ai
-- it filters out missing characters dead characters and characters without a root part
-- so later systems can assume the returned data is valid
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

-- chase movement only cares about horizontal pursuit
-- matching the target X and Z while keeping the npc at its own Y level
-- prevents jumping targets from causing unstable movement or bad path requests
local function getGroundTargetPosition(position)
	return Vector3.new(position.X, root.Position.Y, position.Z)
end

-- line of sight is checked with a raycast from the npc head toward the target root
-- this allows walls and other geometry to block detection
-- so the npc only starts or maintains chase when it can actually see the player
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

-- this searches all current players and returns the closest valid visible target
-- patrol and investigate both use the same search so the npc can re enter chase
-- whenever a player becomes visible again
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

-- this builds a roblox path from the npc position to a destination
-- if path computation fails the function returns nil
-- callers use that result to decide whether they can start path based movement
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

-- once a path is built this stores the waypoint list that later movement code follows
local function usePath(path)
	state.CurrentPath = path
	state.CurrentWaypoints = path:GetWaypoints()
	state.CurrentWaypointIndex = 1
end

-- this advances movement along the current path one waypoint at a time
-- waypoint jump actions are forwarded to the humanoid before MoveTo is called
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

-- this is a support system for small obstacles that pathing may not handle cleanly
-- it only triggers while grounded and moving forward
-- and it checks for a low obstacle with free space above before forcing a jump
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

-- this changes the current high level ai mode
-- later the main loop uses the selected mode to choose the correct state handler
local function setMode(newMode)
	if state.Mode == newMode then
		return
	end

	debugPrint("state", state.Mode, "->", newMode)
	state.Mode = newMode
end

-- path following is valid during investigate
-- and during chase only when chase mode is currently path based
-- this helper is used by movement callbacks to avoid running stale path logic
local function isPathMovementMode()
	if state.Mode == "Investigate" then
		return true
	end

	return state.Mode == "Chase" and state.ChaseMode == "Path"
end

local goToPatrolPoint
local startPatrol
local startPathChase

-- this starts path based movement toward a destination
-- once the path is active a MoveToFinished callback advances the npc through each waypoint
-- the callback only continues while the npc is still in a state that should be following that path
startPathChase = function(destination)
	local path = buildPath(destination)
	if not path then
		return
	end

	usePath(path)
	clearMoveConnection()
	moveToNextWaypoint()

	state.MoveConnection = humanoid.MoveToFinished:Connect(function(reached)
		-- if the npc has been destroyed this old movement callback should stop immediately
		if state.Destroyed then
			return
		end

		-- if the state changed while the path was running this callback is no longer valid
		if not isPathMovementMode() then
			return
		end

		-- only advance to the next waypoint when the last MoveTo actually completed
		if not reached then
			return
		end

		state.CurrentWaypointIndex += 1
		if state.CurrentWaypointIndex <= #state.CurrentWaypoints then
			moveToNextWaypoint()
		end
	end)
end

-- patrol movement uses the same path system as chase and investigate
-- but its destination comes from the current patrol point instead of a moving target
-- when one patrol path is finished the npc waits briefly then advances to the next point
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
		-- if the npc died or left patrol mode the patrol callback should stop here
		if state.Destroyed or state.Mode ~= "Patrol" then
			return
		end

		-- patrol should only continue when the current waypoint was actually reached
		if not reached then
			return
		end

		state.CurrentWaypointIndex += 1
		if state.CurrentWaypointIndex <= #state.CurrentWaypoints then
			moveToNextWaypoint()
			return
		end

		task.delay(config.PatrolWaitTime, function()
			-- if patrol mode changed during the wait do not keep cycling patrol points
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

-- patrol is the neutral default behavior
-- entering patrol clears chase specific and investigate specific data
-- resets movement mode back to path
-- and begins walking toward the next patrol point
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

-- chase begins when a visible player is found
-- this stores the target resets movement tracking and remembers the most recent visible position
-- so investigate mode has a place to go if the target is lost later
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

-- investigate mode is used after a target is lost
-- the npc goes to the last visible position and waits there briefly before returning to patrol
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

-- this is used by attack logic to enforce cooldown timing between hits
local function canAttack()
	return (time() - state.LastAttackTime) >= config.AttackCooldown
end

-- attack handling is separated from chase movement
-- this function only applies damage when the target is still valid
-- in range and off cooldown
local function attackTarget()
	if not state.Target then
		return
	end

	local character, targetHumanoid, targetRoot = getPlayerParts(state.Target)
	if not character or not targetHumanoid or not targetRoot then
		return
	end

	-- if the target is outside melee range damage should not be applied yet
	if (root.Position - targetRoot.Position).Magnitude > config.AttackRange then
		return
	end

	-- cooldown prevents multiple hits from firing every single frame
	if not canAttack() then
		return
	end

	state.LastAttackTime = time()
	targetHumanoid:TakeDamage(config.Damage)
	debugPrint("attacked", state.Target.Name, "for", config.Damage)
end

-- patrol and investigate both use this to re acquire a target
-- if a visible player is found the npc immediately transitions back into chase
local function checkForTarget()
	local visiblePlayer = findClosestVisiblePlayer()
	if visiblePlayer then
		startChase(visiblePlayer)
	end
end

-- direct chase is the close range movement mode
-- it skips pathfinding and repeatedly issues MoveTo calls toward a predicted target position
-- prediction uses the target horizontal velocity so the npc reacts better to motion changes
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

	-- if the predicted point barely changed another MoveTo would just create unnecessary updates
	if state.LastDirectTargetPosition then
		local moveDelta = (predictedPosition - state.LastDirectTargetPosition).Magnitude
		if moveDelta < 1.5 then
			return
		end
	end

	state.LastDirectTargetPosition = predictedPosition

	-- only issue direct movement when the predicted point is meaningfully away from the npc
	if (predictedPosition - root.Position).Magnitude > config.DirectMoveMinDist then
		humanoid:MoveTo(predictedPosition)
	end
end

-- path chase is the long range or obstructed movement mode
-- it rebuilds paths at controlled intervals
-- and avoids rebuilding if the desired chase position is too similar to the current path goal
local function updatePathChase(targetGroundPosition)
	-- repath interval limits how often new paths are requested
	if time() - state.LastRepathTime < config.RepathInterval then
		return
	end

	local chasePosition = state.LastSeenPosition or targetGroundPosition

	-- if the requested chase point barely moved there is no reason to rebuild yet
	if state.LastPathTargetPosition then
		local moveDelta = (chasePosition - state.LastPathTargetPosition).Magnitude
		if moveDelta < config.RepathMinDist then
			return
		end
	end

	-- if the active path is already leading close enough to the new goal keep the current path
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

-- this decides what happens when chase can no longer continue
-- if the npc has a last seen position it investigates first
-- otherwise it returns directly to patrol
local function loseTargetToInvestigate()
	if state.LastSeenPosition then
		startInvestigate(state.LastSeenPosition)
	else
		startPatrol()
	end
end

-- this switches chase into direct movement mode
-- the cooldown prevents constant flipping between movement styles
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

-- this switches chase into path movement mode
-- it also clears path target tracking so the next path rebuild starts clean
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

-- this is the main chase state update
-- it validates the current target checks chase distance handles attacking
-- refreshes the last seen position when visibility is clear
-- and chooses whether movement should be handled by direct chase or path chase
local function updateChase()
	-- if the target disappeared completely the npc can no longer stay in chase
	if not state.Target then
		loseTargetToInvestigate()
		return
	end

	local character, _, targetRoot = getPlayerParts(state.Target)

	-- if the character data is invalid chase should end before movement code runs on bad data
	if not character or not targetRoot then
		debugPrint("lost target because character is invalid")
		loseTargetToInvestigate()
		return
	end

	local targetGroundPosition = getGroundTargetPosition(targetRoot.Position)
	local distance = (root.Position - targetGroundPosition).Magnitude

	-- once the target moves outside the allowed chase range the npc gives up and falls back
	if distance > config.LoseRange then
		debugPrint("lost target due to distance")
		loseTargetToInvestigate()
		return
	end

	attackTarget()

	local hasSight = hasLineOfSight(targetRoot)
	local wantsDirectChase = hasSight and distance < config.DirectChaseRange

	-- last seen should only update while visibility is clear so investigate goes somewhere meaningful
	if hasSight then
		state.LastSeenPosition = targetGroundPosition
	end

	-- close visible targets can use direct movement while other cases stay on path movement
	if wantsDirectChase then
		switchToDirectChase()
	else
		switchToPathChase()
	end

	-- after movement mode is chosen run only the update for that movement style
	if state.ChaseMode == "Direct" then
		updateDirectChase(targetRoot, targetGroundPosition)
		return
	end

	updatePathChase(targetGroundPosition)
end

-- investigate update runs after the npc reaches the last seen position
-- it waits for a short time in case the player becomes visible again
-- then clears the stored location and returns the npc to patrol
local function updateInvestigate()
	if not state.LastSeenPosition then
		startPatrol()
		return
	end

	local distanceToInvestigatePoint = (root.Position - state.LastSeenPosition).Magnitude

	-- stay in investigate until the npc is actually close enough to the stored position
	if distanceToInvestigatePoint > config.InvestigateArriveDistance then
		return
	end

	-- first arrival frame starts the wait timer instead of ending investigate immediately
	if state.InvestigateStartedAt == 0 then
		state.InvestigateStartedAt = time()
		return
	end

	-- keep waiting until the full investigate delay has passed
	if time() - state.InvestigateStartedAt < config.InvestigateWaitTime then
		return
	end

	state.InvestigateStartedAt = 0
	state.LastSeenPosition = nil
	startPatrol()
end

-- this rebuilds chase movement when the npc appears stuck during chase
-- it chooses direct movement if the target is visible and close
-- otherwise it rebuilds a path toward the last seen or current target position
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

-- investigate recovery simply rebuilds a path back to the last seen position
local function recoverInvestigateMovement()
	if not state.LastSeenPosition then
		return
	end

	stopCurrentPath()
	startPathChase(state.LastSeenPosition)
end

-- patrol recovery rebuilds path movement toward the current patrol point
local function recoverPatrolMovement()
	if #state.PatrolPoints == 0 then
		return
	end

	stopCurrentPath()
	goToPatrolPoint()
end

-- this checks for low movement over time to detect when the npc is stuck
-- once the timer passes the threshold it rebuilds movement based on the current state
-- so patrol chase and investigate each recover in a way that matches their own behavior
local function checkIfStuck()
	local movementDelta = (root.Position - state.LastPosition).Magnitude

	-- enough movement means the npc is still making progress so the stuck timer should be cleared
	if movementDelta >= config.StuckThreshold then
		state.StuckStartTime = nil
		state.LastPosition = root.Position
		return
	end

	-- first frame of very low movement starts the stuck timer
	if not state.StuckStartTime then
		state.StuckStartTime = time()
		state.LastPosition = root.Position
		return
	end

	-- low movement has to continue for long enough before recovery should run
	if time() - state.StuckStartTime < config.StuckTime then
		state.LastPosition = root.Position
		return
	end

	debugPrint("npc seems stuck, recalculating")

	-- rebuild movement differently depending on which high level state is currently active
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

-- state handlers define the top level logic for each ai mode
-- the heartbeat loop reads state.Mode and runs the matching handler
-- this keeps the main loop flatter and avoids a large nested state chain
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

-- patrol points are loaded once when the script starts
-- sorting by name keeps patrol order predictable and easy to control from the workspace
for _, point in ipairs(patrolFolder:GetChildren()) do
	if point:IsA("BasePart") then
		table.insert(state.PatrolPoints, point)
	end
end

table.sort(state.PatrolPoints, function(a, b)
	return a.Name < b.Name
end)

startPatrol()

-- main update loop
-- this runs every frame and drives the ai system forward
-- it selects the active state handler first
-- then runs shared movement support systems that apply across all states
-- this separation makes the flow easier to follow and debug
local heartbeatConnection
heartbeatConnection = RunService.Heartbeat:Connect(function()
	-- stop the system entirely once the npc is dead or removed from the world
	if not isAlive() then
		state.Destroyed = true
		clearMoveConnection()
		heartbeatConnection:Disconnect()
		return
	end

	local handler = StateHandlers[state.Mode]

	-- each frame only the handler for the current state should run
	if handler then
		handler()
	end

	tryAutoJump()
	checkIfStuck()
end)

-- cleanup is handled on death so movement callbacks do not keep running after the npc is gone
humanoid.Died:Connect(function()
	state.Destroyed = true
	clearMoveConnection()
end)
