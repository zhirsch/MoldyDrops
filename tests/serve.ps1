param([string]$Root = $PSScriptRoot, [int]$Port = 8765)
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Start()
Write-Host "Serving $Root on http://localhost:$Port/"
while ($listener.IsListening) {
  $ctx = $listener.GetContext()
  $name = $ctx.Request.Url.AbsolutePath.TrimStart('/')
  if ($name -eq '') { $name = 'index.html' }
  $path = Join-Path $Root $name
  if ((Test-Path $path -PathType Leaf) -and ([IO.Path]::GetFullPath($path).StartsWith([IO.Path]::GetFullPath($Root)))) {
    $bytes = [IO.File]::ReadAllBytes($path)
    $ctx.Response.ContentType = 'text/html; charset=utf-8'
    $ctx.Response.ContentLength64 = $bytes.Length
    $ctx.Response.Headers.Add('Cache-Control', 'no-store')
    $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
  } else {
    $ctx.Response.StatusCode = 404
  }
  $ctx.Response.Close()
}
