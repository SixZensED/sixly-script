local lists = {
        [10035204815] = "ride-a-pet",
        [10512942223] = "anime-zero",
}
local name = lists[game.GameId]

loadstring(game:HttpGet("https://raw.githubusercontent.com/SixZensED/sixly-script/refs/heads/main/games/"..name..".lua"))()
