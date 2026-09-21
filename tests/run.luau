--!strict
-- Entry point for CI: `lune run tests/run`.
--
-- Requiring a *.spec.luau file registers its tests as a side effect (it
-- calls TestRunner.describe/it at module scope). Add every new spec file
-- to the require list below — there's no auto-discovery, deliberately,
-- to keep this runner dependency-free and its behavior obvious to read.

local TestRunner = require("./TestRunner")

require("./Loader.spec")
require("./Net.spec")
require("./Config.spec")
require("./ProfileLogic.spec")
require("./RoundStates.spec")
require("./Clock.spec")
require("./Qualification.spec")
require("./TaskAssignment.spec")
require("./PowerUpLogic.spec")
-- require("./Outcomes.spec") -- add once src/shared/Config/Outcomes.luau exists

TestRunner.run()
