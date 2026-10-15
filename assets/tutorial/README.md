# Tutorial step pictures

One picture per guided-round step (`OnboardingLogic.STEPS[].picture`),
shown in the step's pop-up. Studio Play screenshots on Factory, cropped
to 16:9 and saved at 960x540.

| File | Step | Asset id |
|---|---|---|
| step-station.png | Head to a station | 72834010784044 |
| step-task.png | Do the task | 110568131773173 |
| step-grab.png | Grab a power-up | 103735767545857 |
| step-use.png | Use it on a bot | 77015988624200 |
| step-finish.png | Finish your tasks | 114091474180130 |

How they were taken: a tutorial round in Match_Area (DebugPracticeMatch +
DebugTutorialMatch on, `studioTest.mapId = "Factory"`), the camera pinned
from the Client DM with `BindToRenderStep`, ScreenGuis hidden as needed,
and the player and a bot placed from the Server DM. The finish shot's HUD
(4/6 ticked, 2nd place) was set by hand on the client for the picture.
Upload: serve the folder on localhost (`python -m http.server 8766`) and
call Studio MCP `upload_image`.
