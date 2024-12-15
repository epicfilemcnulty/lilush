local mods_to_string = function(mods)
    local keys = {
        [1] = "SHIFT",
        [2] = "ALT",
        [4] = "CTRL",
        [8] = "SUPER",
        [16] = "HYPER",
        [32] = "META",
        [64] = "CAPS_LOCK",
        [128] = "NUM_LOCK",
    }
    local combination = {}
    for key, value in pairs(keys) do
        if bit.band(mods, key) ~= 0 then
            table.insert(combination, value)
        end
    end
    return table.concat(combination, "+")
end

local string_to_mods = function(combination)
    local keys = {
        SHIFT = 1,
        ALT = 2,
        CTRL = 4,
        SUPER = 8,
        HYPER = 16,
        META = 32,
        CAPS_LOCK = 64,
        NUM_LOCK = 128,
    }
    local byte = 0
    local modifiers = {}
    for modifier in string.gmatch(combination, "%w+") do
        table.insert(modifiers, modifier)
    end
    for _, modifier in ipairs(modifiers) do
        if keys[modifier] then
            byte = bit.bor(byte, keys[modifier])
        end
    end
    return byte
end

return {
    mods_to_string = mods_to_string,
    string_to_mods = string_to_mods
}
