--!strict
-- The component library (P6-2). Screens require this, not the files:
--   local C = require(UI.Components)
--   C.Button({ label = "Ready", onActivate = ... })
-- Built on Vide (centau/vide); see docs/components.md.

return table.freeze({
	Button = require(script.Button),
	IconButton = require(script.IconButton),
	Panel = require(script.Panel),
	Modal = require(script.Modal),
	ProgressBar = require(script.ProgressBar),
	CountdownRing = require(script.CountdownRing),
	Toast = require(script.Toast),
	TaskCard = require(script.TaskCard),
	PlayerRow = require(script.PlayerRow),
	CurrencyPill = require(script.CurrencyPill),
	TabBar = require(script.TabBar),
	Icons = require(script.Icons),
	Env = require(script.Env),
})
