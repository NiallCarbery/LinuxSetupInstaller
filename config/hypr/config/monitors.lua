-- Monitor wiki https://wiki.hypr.land/Configuring/Basics/Monitors/
-- Example: output can be found with hyprctl monitors. Edit variables.lua for the monitor outputs instead of here directly
-- hl.monitor({
--     output    = MONITOR1,
--     mode      = "1920x1080@60",
--     position  = "0x0",
--     scale     = "1",
-- })

hl.env(
    "AQ_DRM_DEVICES",
    "/dev/dri/amd-igpu:/dev/dri/nvidia-dgpu"
)

--------------------------------------------------
-- Power profile integration
--------------------------------------------------

hl.on("hyprland.start", function()
    hl.exec_cmd("$HOME/.local/bin/hypr-power-profile watch")
end)


--------------------------------------------------
-- Laptop lid
--------------------------------------------------

hl.bind(
    "switch:on:Lid Switch",
    hl.dsp.exec_cmd("$HOME/.local/bin/hypr-power-profile lid-close"),
    { locked = true }
)

hl.bind(
    "switch:off:Lid Switch",
    hl.dsp.exec_cmd("$HOME/.local/bin/hypr-power-profile lid-open"),
    { locked = true }
)

hl.monitor({
    output = "",
    mode = "preferred",
    position = "auto",
    scale = 1,
})
