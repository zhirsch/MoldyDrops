# Builds tests/index.html: the addon's Lua files plus harness.lua, run in the browser by Fengari.
param([string]$Addon = (Join-Path $PSScriptRoot '..\MoldyDrops'), [string]$Out = $PSScriptRoot)
$src = [ordered]@{}
foreach ($f in 'BaseData','Core','Codec','Recorder','Tooltip','Search') { $src[$f] = [IO.File]::ReadAllText((Join-Path $Addon "$f.lua")) }
$src['HARNESS'] = [IO.File]::ReadAllText((Join-Path $Out 'harness.lua'))
$json = $src | ConvertTo-Json -Compress
$html = "<!doctype html><meta charset=utf-8><title>MoldyDrops tests</title><pre id=out>running...</pre><script>window.SRC = $json;</script><script src=`"https://cdn.jsdelivr.net/npm/fengari-web@0.1.4/dist/fengari-web.js`"></script><script>try { window.RESULT = String(fengari.load(SRC.HARNESS, 'harness')()); } catch (e) { window.RESULT = 'ERROR: ' + (e && e.message || e); } document.getElementById('out').textContent = window.RESULT;</script>"
[IO.File]::WriteAllText((Join-Path $Out 'index.html'), $html, (New-Object Text.UTF8Encoding($false)))
