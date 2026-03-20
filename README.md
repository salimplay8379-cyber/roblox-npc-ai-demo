## Code Example

```lua
-- Example of NPC detection and behavior
if self:CanSeePlayer(target) then
    self:Chase(target)
else
    self:Patrol()
end
```

## Features Breakdown

- Modular AI system (clean and expandable)
- Uses PathfindingService for navigation
- Line-of-sight detection using raycasting
- State-based behavior (patrol, chase, attack)
- Automatic obstacle handling and jumping
- Optimized for performance and scalability

## Portfolio

You can view more of my Roblox scripting work here:  
https://salimluau1.carrd.co/
