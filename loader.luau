local lists = {
        [10035204815] = "ride-a-pet",
        [10684750879] = "loot-to-forge",
}
local name = lists[game.GameId]

loadstring(game:HttpGet("https://raw.githubusercontent.com/SixZensED/sixly-script/refs/heads/main/games/"..name..".lua"))()
