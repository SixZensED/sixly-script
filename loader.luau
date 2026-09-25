local lists = {
        [10035204815] = "ride-a-pet",
}
local name = lists[game.GameId]

loadstring(game:HttpGet("https://raw.githubusercontent.com/SixZensED/sixly-script/refs/heads/main/games/"..name..".lua"))()
