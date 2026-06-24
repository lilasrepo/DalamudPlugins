<#
.SYNOPSIS
  Publish TC (Traditional-Chinese, API12, game 7.1) Dalamud plugin ports to the `lilasrepo`
  GitHub account as per-plugin forks + GitHub releases + an aggregating pluginmaster.json.

.DESCRIPTION
  For each selected plugin this script:
    1. Forks the real upstream into lilasrepo (preserves the GitHub "forked from" badge).
    2. Pushes the TC_forward/<plugin> source onto the fork's `main` (source code visible).
    3. Zips the built TC_plugin/<InternalName> staging tree and cuts a `v<ver>-TC12` release.
  Then it regenerates the single pluginmaster.json (served raw from lilasrepo/DalamudPlugins)
  containing every plugin that currently has a published release.

  SAFE BY DEFAULT: prints the plan and changes NOTHING unless you pass -Execute.
  SCOPED: aborts unless `gh` is currently authenticated as the target account (default lilasrepo);
  it never touches any other account.

.EXAMPLE
  # 1. dry-run the pilot (AutoHook) -- prints what it would do, no changes:
  pwsh -File publish-lilasrepo.ps1

  # 2. actually run the pilot end-to-end:
  pwsh -File publish-lilasrepo.ps1 -Execute

  # 3. after verifying AutoHook installs in the TC client, do all 25:
  pwsh -File publish-lilasrepo.ps1 -All -Execute

  # other switches:
  #   -Plugins AutoHook,Lifestream   pick a subset
  #   -ManifestOnly                  only regenerate+push pluginmaster.json
  #   -SkipSource / -SkipRelease     skip a stage
#>
[CmdletBinding()]
param(
  [string[]]$Plugins = @('AutoHook'),
  [switch]$All,
  [switch]$Execute,
  [string]$SourceRoot   = $env:TC_DALAMUD_ROOT,   # pass -SourceRoot or set $env:TC_DALAMUD_ROOT; no hardcoded path so this script is safe to publish
  [string]$Account      = 'lilasrepo',
  [string]$ManifestRepo = 'DalamudPlugins',
  [string]$ApiSuffix    = 'TC12',
  [int]   $ApiLevel     = 12,
  [switch]$SkipSource,
  [switch]$SkipRelease,
  [switch]$ManifestOnly,
  [switch]$AllowStaleRepublish,   # override the frozen-version soft-block (publish a same-version re-clobber anyway, e.g. icon/manifest-only)
  [string[]]$FreshHistory = @()   # plugin name(s) (Src/Stage/repo) to publish as ONE clean orphan commit + force-push (wipes prior history; use to scrub a past leak)
)

$ErrorActionPreference = 'Stop'
$DryRun = -not $Execute

# ---- authoritative plugin table (Src = TC_forward dir, Stage = TC_plugin/InternalName dir, Up = upstream owner/repo) ----
$Table = @(
  @{ Src='AntiAfkKick';          Stage='AntiAfkKick';        Up='NightmareXIV/AntiAfkKick' }
  @{ Src='Artisan';              Stage='Artisan';            Up='PunishXIV/Artisan' }
  @{ Src='AutoDuty';             Stage='AutoDuty';           Up='erdelf/AutoDuty' }
  @{ Src='AutoHook';             Stage='AutoHook';           Up='PunishXIV/AutoHook' }
  @{ Src='AutoRetainer';         Stage='AutoRetainer';       Up='PunishXIV/AutoRetainer' }
  @{ Src='Dalamud.SkipCutscene'; Stage='SkipCutscene';       Up='KangasZ/SkipCutscene' }
  @{ Src='ffxiv_bossmod';        Stage='BossMod';            Up='awgil/ffxiv_bossmod' }
  @{ Src='ffxiv_navmesh';        Stage='vnavmesh';           Up='awgil/ffxiv_navmesh' }
  @{ Src='ffxiv-bundleoftweaks'; Stage='Automaton';          Up='Jaksuhn/ffxiv-bundleoftweaks' }
  @{ Src='ffxiv-priceinsight';   Stage='PriceInsight';       Up='Kouzukii/ffxiv-priceinsight' }
  @{ Src='GatherBuddyReborn';    Stage='GatherBuddyReborn';  Up='AtmoOmen/GatherBuddyReborn' }
  @{ Src='Gearsetter';           Stage='Gearsetter';         Up='VeraNala/Gearsetter' }
  @{ Src='Lifestream';           Stage='Lifestream';         Up='NightmareXIV/Lifestream' }
  @{ Src='NoClippy';             Stage='NoClippy';           Up='UnknownX7/NoClippy' }
  @{ Src='NotificationMaster';   Stage='NotificationMaster'; Up='NightmareXIV/NotificationMaster' }
  @{ Src='Orbwalker';            Stage='Orbwalker';          Up='PunishXIV/Orbwalker' }
  @{ Src='PalacePal';            Stage='PalacePal';          Up='PunishXIV/PalacePal' }
  @{ Src='PandorasBox';          Stage='PandorasBox';        Up='PunishXIV/PandorasBox' }
  @{ Src='Questionable';         Stage='Questionable';       Up='PunishXIV/Questionable' }
  @{ Src='Saucy';                Stage='Saucy';              Up='PunishXIV/Saucy' }
  @{ Src='SomethingNeedDoing';   Stage='SomethingNeedDoing'; Up='Jaksuhn/SomethingNeedDoing' }
  @{ Src='Splatoon';             Stage='Splatoon';           Up='PunishXIV/Splatoon' }
  @{ Src='TextAdvance';          Stage='TextAdvance';        Up='NightmareXIV/TextAdvance' }
  @{ Src='WrathCombo';           Stage='WrathCombo';         Up='PunishXIV/WrathCombo' }
  @{ Src='YesAlready';           Stage='YesAlready';         Up='PunishXIV/YesAlready' }
)

# ---- icon self-hosting (2026-06-15) ----
# The per-plugin manifest IconUrl is unreliable: puni.sh migrated love.puni.sh -> s3, several
# github raw paths moved (404), and carvel.li went away entirely (NXDOMAIN). So for these we serve
# the icon from THIS repo (lilasrepo/DalamudPlugins/icons/<InternalName>.png) instead of trusting
# upstream. PNGs live next to this script in ./icons and get pushed alongside pluginmaster.json.
# This is refresh-proof: it does NOT depend on the plugin manifest, which /plugin_update overwrites.
$IconDir = Join-Path $PSScriptRoot 'icons'
# InternalName -> served from $ManifestRepo/icons/<InternalName>.png (real upstream icon, re-hosted):
$SelfHostedIcons = @(
  'AntiAfkKick-Dalamud','Artisan','GatherBuddyReborn','Lifestream','NotificationMaster',
  'Orbwalker','PriceInsight','Splatoon','TextAdvance'
)
# InternalName -> upstream NEVER shipped an icon; force blank so Dalamud uses its placeholder
# (also clears Gearsetter's dead carvel.li URL). Supply a custom PNG + move to $SelfHostedIcons later.
$BlankIcons = @('Gearsetter','SkipCutscene','NoClippy')

# ---------------------------------------------------------------------------- helpers ----
function Resolve-Gh {
  $c = Get-Command gh -ErrorAction SilentlyContinue
  if ($c) { return $c.Source }
  $p = Join-Path $env:ProgramFiles 'GitHub CLI\gh.exe'
  if (Test-Path $p) { return $p }
  throw "gh CLI not found. Install GitHub CLI or add it to PATH."
}
$Gh = Resolve-Gh

function Gh { param([Parameter(ValueFromRemainingArguments=$true)]$a)
  $out = & $Gh @a 2>&1 | Out-String
  return [pscustomobject]@{ Ok = ($LASTEXITCODE -eq 0); Out = $out }
}
function Hide-Token([string]$s,[string]$tok){ if ($tok) { $s -replace [regex]::Escape($tok),'***' } else { $s } }

function Get-StageManifest([string]$stageDir){
  if (-not (Test-Path $stageDir)) { return $null }
  foreach ($f in (Get-ChildItem -LiteralPath $stageDir -Filter *.json -File)) {
    try { $c = Get-Content -Raw -LiteralPath $f.FullName | ConvertFrom-Json } catch { continue }
    $names = $c.PSObject.Properties.Name
    if (($names -contains 'AssemblyVersion') -and ($names -contains 'InternalName')) {
      return [pscustomobject]@{ File = $f.FullName; Data = $c }
    }
  }
  return $null
}

# Display marker shown in the plugin installer. Derived from $ApiLevel so a future TC API
# bump only needs -ApiLevel changed. Idempotent: strips any prior "(TCxx)" or "[TC apixx]"
# suffix (incl. the staged name pre-stamped by scripts/stamp-tc-marker.ps1) before re-appending.
function Get-DisplayName([string]$raw){
  $base = ($raw -replace '\s*\(TC\d+\)\s*$','' -replace '\s*\[TC\s*api\d+\]\s*$','').Trim()
  return "$base [TC api$ApiLevel]"
}
function New-Entry($m,[string]$repo,[string]$tag){
  $name = Get-DisplayName ([string]$m.Name)
  $dl = "https://github.com/$Account/$repo/releases/download/$tag/$($m.InternalName).zip"
  $internal = [string]$m.InternalName
  if ($SelfHostedIcons -contains $internal) {
    $icon = "https://raw.githubusercontent.com/$Account/$ManifestRepo/main/icons/$internal.png"
  } elseif ($BlankIcons -contains $internal) {
    $icon = ''
  } else {
    $icon = if ($m.IconUrl) { [string]$m.IconUrl } else { '' }
  }
  return [ordered]@{
    Author              = [string]$m.Author
    Name                = $name
    InternalName        = [string]$m.InternalName
    AssemblyVersion     = [string]$m.AssemblyVersion
    Description         = [string]$m.Description
    Punchline           = [string]$m.Punchline
    ApplicableVersion   = 'any'
    RepoUrl             = "https://github.com/$Account/$repo"
    DalamudApiLevel     = $ApiLevel
    Tags                = @($m.Tags)
    IconUrl             = $icon
    DownloadLinkInstall = $dl
    DownloadLinkUpdate  = $dl
    DownloadLinkTesting = $dl
    LastUpdate          = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  }
}

function Write-Utf8NoBom([string]$path,[string]$text){
  [System.IO.File]::WriteAllText($path,$text,(New-Object System.Text.UTF8Encoding($false)))
}

# Layer-1 frozen-version guard: a refresh that changes a plugin's BUILD but NOT its AssemblyVersion
# publishes as a same-tag --clobber, and the in-game updater (which keys on AssemblyVersion) never
# offers it to installed clients. Stranded <=> the v<ver>-TC12 tag already exists AND a BUILD-RELEVANT
# file under TC_forward/<Src> changed AFTER that tag was first created (= the version's content moved
# without the version number moving; anyone who installed the original v-build is stuck). We compare
# against the tag's CREATION time (which a --clobber does NOT advance), so the warning persists after a
# clobber until the operator actually bumps + cuts a new tag (then the window resets and it self-clears).
# Doc-only churn (README/LICENSE/CONTRIBUTING/.github) is excluded so a docs commit never trips it.
# Any gh/git error => not-stale (no false alarm). Read-only; safe in dry-run + execute.
function Test-StaleRepublish([string]$repo,[string]$tag,[string]$srcRel,[string]$root){
  # raw ISO createdAt (UTC, e.g. 2026-06-24T12:59:04Z) — use --jq so ConvertFrom-Json doesn't mangle the tz
  $rel = Gh release view $tag --repo "$Account/$repo" --json createdAt --jq .createdAt
  if (-not $rel.Ok) { return [pscustomobject]@{ Stale=$false; Note='new version (no existing tag)' } }
  $created = $rel.Out.Trim()
  if (-not $created) { return [pscustomobject]@{ Stale=$false; Note='tag exists; createdAt unknown' } }
  if (-not (Test-Path (Join-Path $root $srcRel))) { return [pscustomobject]@{ Stale=$false; Note='no source dir' } }
  $inv = [cultureinfo]::InvariantCulture
  $createdDto = $null
  try { $createdDto = [datetimeoffset]::Parse($created, $inv) } catch { return [pscustomobject]@{ Stale=$false; Note="unparseable createdAt '$created'" } }
  # most recent build-relevant commit touching the plugin (committer date %cI, with tz), docs excluded
  $gitArgs = @('-C', $root, 'log', '-1', '--format=%cI', '--', $srcRel,
    ":(exclude,glob)$srcRel/**/*.md", ":(exclude,glob)$srcRel/**/README*",
    ":(exclude,glob)$srcRel/**/LICENSE*", ":(exclude,glob)$srcRel/**/CONTRIBUTING*",
    ":(exclude,glob)$srcRel/**/.github/**",
    ":(exclude)$srcRel/.walkback-paths", ":(exclude)$srcRel/.walkback-counter.json")
  $lastStr = (& git @gitArgs 2>$null | Select-Object -First 1)
  if (-not $lastStr) { return [pscustomobject]@{ Stale=$false; Note='no build-relevant commit' } }
  $lastDto = $null
  try { $lastDto = [datetimeoffset]::Parse($lastStr.Trim(), $inv) } catch { return [pscustomobject]@{ Stale=$false; Note="unparseable commit date '$lastStr'" } }
  if ($lastDto -gt $createdDto) {
    return [pscustomobject]@{ Stale=$true; Note="build-relevant commit ($($lastDto.ToString('u'))) is newer than tag created ($($createdDto.ToString('u')))" }
  }
  return [pscustomobject]@{ Stale=$false; Note='no build-relevant change since release' }
}

# ---------------------------------------------------------------------------- preflight ----
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host (" lilasrepo publish  |  mode = {0}" -f $(if($DryRun){'DRY-RUN (no changes)'}else{'EXECUTE'})) -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

if (-not $SourceRoot -or -not (Test-Path -LiteralPath $SourceRoot)) {
  throw "SourceRoot '$SourceRoot' not set or not found. Pass -SourceRoot <path to your FFXIV-Dalamud-TC checkout> (or set `$env:TC_DALAMUD_ROOT)."
}
Write-Host "source root: $SourceRoot" -ForegroundColor Green

$who = Gh api user --jq .login
if (-not $who.Ok) { throw "gh is not authenticated. Run: gh auth login" }
$active = $who.Out.Trim()
if ($active -ne $Account) {
  throw "Active gh account is '$active', expected '$Account'. Run: gh auth switch -u $Account   (aborting; will not touch '$active')"
}
Write-Host "gh account OK: $active" -ForegroundColor Green

$token = ''
if (-not $DryRun) {
  $t = Gh auth token
  if (-not $t.Ok) { throw "could not read gh auth token" }
  $token = $t.Out.Trim()
}

# normalise -Plugins: allow a comma-joined single arg (e.g. "A,B") passed via `pwsh -File`
$Plugins = @($Plugins | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

# select plugins
$selected = if ($All) { $Table } else {
  $Table | Where-Object {
    $r = $_
    $Plugins | Where-Object {
      $_ -ieq $r.Src -or $_ -ieq $r.Stage -or $_ -ieq ($r.Up.Split('/')[-1])
    }
  }
}
if (-not $selected) { throw "no matching plugins for: $($Plugins -join ', ') (use -All for everything)" }
Write-Host ("plugins: {0}" -f (($selected | ForEach-Object { $_.Stage }) -join ', ')) -ForegroundColor Yellow
Write-Host ""

$work  = Join-Path $env:TEMP ("lilasrepo-work-" + [guid]::NewGuid().ToString('N').Substring(0,8))
$results = @()
$staleWarnings = @()   # Layer-1: plugins whose staged version == an existing tag but build is newer
$staleMap = @{}        # Stage -> note (populated by the pre-flight below)

# ------------------------------------------------ Layer-1 frozen-version pre-flight (read-only) ----
# Runs BEFORE any outward action so the soft-block can abort execute with nothing pushed.
if (-not $ManifestOnly) {
  foreach ($p in $selected) {
    $repo = $p.Up.Split('/')[-1]
    $man  = Get-StageManifest (Join-Path $SourceRoot ("TC_plugin\" + $p.Stage))
    if (-not $man) { continue }
    $ver = [string]$man.Data.AssemblyVersion
    $tag = "v$ver-$ApiSuffix"
    $st  = Test-StaleRepublish $repo $tag ("TC_forward/" + $p.Src) $SourceRoot
    if ($st.Stale) {
      $staleMap[$p.Stage] = $st.Note
      $staleWarnings += $p.Stage
      Write-Host ("WARNING frozen-version: {0} v{1} already published, but {2}." -f $p.Stage,$ver,$st.Note) -ForegroundColor Red
      Write-Host  "         -> re-clobbers the SAME tag; installed clients will NOT be offered the update. Bump <Version> first." -ForegroundColor Red
    }
  }
  if ($staleMap.Count -gt 0 -and -not $DryRun -and -not $AllowStaleRepublish) {
    $names = ($staleMap.Keys | Sort-Object) -join ', '
    $msg = "ABORT (frozen-version soft-block): $($staleMap.Count) selected plugin(s) would re-clobber an unchanged version and never reach installed clients: $names. "
    $msg += "Bump <Version> for each first -- pinned/TC-managed: re-run /plugin_update (Layer-2 auto-bump) or 'plugin_update.py bump --plugin <name>'; tracks-upstream: bump the 4th component by hand. "
    $msg += "To publish anyway (e.g. an icon/manifest-only re-clobber), re-run with -AllowStaleRepublish."
    Write-Host ""
    throw $msg
  }
  if ($staleMap.Count -gt 0) { Write-Host "" }
}

# ---------------------------------------------------------------------------- per-plugin ----
if (-not $ManifestOnly) {
foreach ($p in $selected) {
  $repo  = $p.Up.Split('/')[-1]
  $stage = Join-Path $SourceRoot ("TC_plugin\" + $p.Stage)
  $src   = Join-Path $SourceRoot ("TC_forward\" + $p.Src)
  $r = [ordered]@{ Plugin=$p.Stage; Repo=$repo; Source='-'; Release='-'; Status='ok'; Note='' }
  try {
    Write-Host "----- $($p.Stage)  ($($p.Up) -> $Account/$repo)" -ForegroundColor White

    $man = Get-StageManifest $stage
    if (-not $man) { $r.Status='skip'; $r.Note="no built staging manifest at $stage (build it first)"; Write-Host "  ! $($r.Note)" -ForegroundColor DarkYellow; $results+=[pscustomobject]$r; continue }
    $ver = [string]$man.Data.AssemblyVersion
    $internal = [string]$man.Data.InternalName
    $tag = "v$ver-$ApiSuffix"
    $title = "$(Get-DisplayName ([string]$man.Data.Name)) $ver"
    Write-Host "  manifest: InternalName=$internal  ver=$ver  tag=$tag"

    # Layer-1 frozen-version: flagged in the pre-flight above (soft-block already enforced for execute)
    if ($staleMap.ContainsKey($p.Stage)) {
      $r.Note = "FROZEN-VERSION: $($staleMap[$p.Stage])"
      if ($AllowStaleRepublish) { Write-Host "  (frozen-version override: publishing same-version re-clobber)" -ForegroundColor DarkYellow }
    }

    # ---- 1. fork ----
    $have = Gh repo view "$Account/$repo" --json name
    if (-not $have.Ok) {
      if ($DryRun) { Write-Host "  [dry] gh repo fork $($p.Up) --clone=false" -ForegroundColor DarkGray }
      else {
        Write-Host "  forking $($p.Up) ..."
        $f = Gh repo fork $p.Up --clone=false
        if (-not $f.Ok) { throw "fork failed: $($f.Out.Trim())" }
        for ($i=0; $i -lt 30; $i++) { Start-Sleep 2; if ((Gh repo view "$Account/$repo" --json name).Ok) { break } }
      }
    } else { Write-Host "  fork exists" }

    # ---- 2. push TC source onto main ----
    if ($SkipSource) { $r.Source='skip' }
    elseif (-not (Test-Path $src)) { $r.Source='skip'; $r.Note='no TC_forward source dir' }
    elseif ($DryRun) {
      $fresh = [bool]($FreshHistory | Where-Object { $_ -ieq $p.Src -or $_ -ieq $p.Stage -or $_ -ieq $repo })
      $r.Source = if ($fresh) { 'would-push(fresh)' } else { 'would-push' }
      Write-Host ("  [dry] clone $Account/$repo, replace tree with $src, commit, " + $(if($fresh){'FORCE-push ORPHAN (wipes history)'}else{'push HEAD:main'}) + ", set default-branch main") -ForegroundColor $(if($fresh){'Yellow'}else{'DarkGray'})
    } else {
      $fresh = [bool]($FreshHistory | Where-Object { $_ -ieq $p.Src -or $_ -ieq $p.Stage -or $_ -ieq $repo })
      if (Test-Path $work) { Remove-Item -Recurse -Force $work }
      git clone --filter=blob:none "https://github.com/$Account/$repo.git" $work 2>&1 | Out-Null
      if ($LASTEXITCODE -ne 0) { throw "clone failed" }
      if ($fresh) { git -C $work checkout --orphan freshmain 2>&1 | Out-Null }
      else        { git -C $work checkout -B main 2>&1 | Out-Null }
      # wipe working tree except .git
      Get-ChildItem -LiteralPath $work -Force | Where-Object Name -ne '.git' | Remove-Item -Recurse -Force
      # copy TC source (incl. dotfiles)
      Get-ChildItem -LiteralPath $src -Force | Copy-Item -Destination $work -Recurse -Force
      # prune build/junk; keep ROOT .git, drop nested .git + .gitmodules
      Get-ChildItem -LiteralPath $work -Recurse -Force -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -in @('bin','obj','.vs') } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
      Get-ChildItem -LiteralPath $work -Recurse -Force -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq '.git' -and $_.FullName -ne (Join-Path $work '.git') } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
      Get-ChildItem -LiteralPath $work -Recurse -Force -File -Filter '.gitmodules' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

      git -C $work add -A 2>&1 | Out-Null
      $outerSha = (& git -C $SourceRoot rev-parse --short HEAD 2>$null)
      git -C $work -c user.name='lilasrepo' -c user.email='lilasrepo@users.noreply.github.com' commit -m "port($($p.Stage)): TC API12 source (based on TC_forward @ $outerSha)" 2>&1 | Out-Null
      if (-not $fresh -and $LASTEXITCODE -ne 0) { $r.Source='no-change'; Write-Host "  source unchanged" }
      else {
        $pushUrl = "https://$Account`:$token@github.com/$Account/$repo.git"
        if ($fresh) {
          git -C $work branch -M main 2>&1 | Out-Null
          Write-Host "  fresh history: single clean orphan commit, force-push (scrubs prior history)" -ForegroundColor Yellow
          $o = git -C $work push -f $pushUrl HEAD:main 2>&1 | Out-String
        } else {
          $o = git -C $work push $pushUrl HEAD:main 2>&1 | Out-String
        }
        Write-Host ("  " + (Hide-Token $o $token).Trim())
        if ($LASTEXITCODE -ne 0) { throw "push failed" }
        Gh repo edit "$Account/$repo" --default-branch main | Out-Null
        $r.Source = if ($fresh) { 'pushed(fresh)' } else { 'pushed' }
      }
      Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
    }

    # ---- 3. release ----
    if ($SkipRelease) { $r.Release='skip' }
    elseif ($DryRun) {
      $r.Release='would-release'
      Write-Host "  [dry] zip $stage -> $internal.zip ; gh release ($tag) on $Account/$repo" -ForegroundColor DarkGray
    } else {
      $zip = Join-Path $env:TEMP "$internal.zip"
      if (Test-Path $zip) { Remove-Item -Force $zip }
      Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -Force
      $rel = Gh release view $tag --repo "$Account/$repo" --json tagName
      if ($rel.Ok -and $fresh) {
        # the tag still points at the PRE-scrub commit (e.g. the one carrying .tools); the orphan
        # force-push only rewrote main, so delete release+tag and re-cut on the clean main HEAD.
        Write-Host "  fresh history: deleting release+tag so it re-tags the scrubbed HEAD" -ForegroundColor Yellow
        Gh release delete $tag --repo "$Account/$repo" --cleanup-tag --yes | Out-Null
        $rel = [pscustomobject]@{ Ok = $false }
      }
      if ($rel.Ok) {
        $u = Gh release upload $tag $zip --repo "$Account/$repo" --clobber
        if (-not $u.Ok) { throw "release upload failed: $($u.Out.Trim())" }
        $r.Release='updated'
      } else {
        $notes = "Traditional-Chinese ($ApiSuffix / Dalamud API$ApiLevel / game 7.1) port of $($man.Data.Name) $ver. Built from TC_forward."
        $c = Gh release create $tag --repo "$Account/$repo" --target main --title $title --notes $notes $zip
        if (-not $c.Ok) { throw "release create failed: $($c.Out.Trim())" }
        $r.Release='created'
      }
      Remove-Item -Force $zip -ErrorAction SilentlyContinue
      Write-Host "  release $($r.Release): $tag"
    }
  } catch {
    $r.Status='FAIL'; $r.Note=$_.Exception.Message
    Write-Host "  FAIL: $($_.Exception.Message)" -ForegroundColor Red
  }
  $results += [pscustomobject]$r
  Write-Host ""
}
}

# ---------------------------------------------------------------------------- manifest ----
Write-Host "----- pluginmaster.json -----" -ForegroundColor White
$entries = @()
foreach ($p in $Table) {
  $repo  = $p.Up.Split('/')[-1]
  $stage = Join-Path $SourceRoot ("TC_plugin\" + $p.Stage)
  $man = Get-StageManifest $stage
  if (-not $man) { continue }
  $ver = [string]$man.Data.AssemblyVersion
  $tag = "v$ver-$ApiSuffix"
  if ($DryRun) {
    # in dry-run, include the plugins we are processing this run (releases may not exist yet)
    if (($All) -or ($selected | Where-Object { $_.Stage -eq $p.Stage })) { $entries += (New-Entry $man.Data $repo $tag) }
  } else {
    $rel = Gh release view $tag --repo "$Account/$repo" --json tagName
    if ($rel.Ok) { $entries += (New-Entry $man.Data $repo $tag) }
  }
}

if (-not $entries) { Write-Host "  (no entries to write)"; }
else {
  $parts = $entries | ForEach-Object { $_ | ConvertTo-Json -Depth 6 }
  $json  = "[`n" + ($parts -join ",`n") + "`n]"
  $localManifest = Join-Path $env:TEMP 'pluginmaster.json'
  Write-Utf8NoBom $localManifest $json
  Write-Host ("  wrote {0} entries -> {1}" -f $entries.Count, $localManifest)
  Write-Host ("  plugins: {0}" -f (($entries | ForEach-Object { $_.InternalName }) -join ', '))

  if ($DryRun) {
    Write-Host "  [dry] gh repo create $Account/$ManifestRepo --public (if absent); push pluginmaster.json + icons/ to main" -ForegroundColor DarkGray
    if (Test-Path $IconDir) { Write-Host ("  [dry] would sync {0} self-hosted icons from {1}" -f (Get-ChildItem $IconDir -Filter *.png).Count, $IconDir) -ForegroundColor DarkGray }
  } else {
    if (-not (Gh repo view "$Account/$ManifestRepo" --json name).Ok) {
      $c = Gh repo create "$Account/$ManifestRepo" --public --add-readme
      if (-not $c.Ok) { throw "manifest repo create failed: $($c.Out.Trim())" }
      Start-Sleep 3
    }
    $mwork = Join-Path $env:TEMP ("lilasrepo-manifest-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    if (Test-Path $mwork) { Remove-Item -Recurse -Force $mwork }
    git clone "https://github.com/$Account/$ManifestRepo.git" $mwork 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "manifest repo clone failed" }
    git -C $mwork checkout -B main 2>&1 | Out-Null
    # sync self-hosted icons (./icons/*.png) into the manifest repo so the IconUrls resolve
    $iconNote = ''
    if (Test-Path $IconDir) {
      $destIcons = Join-Path $mwork 'icons'
      New-Item -ItemType Directory -Force -Path $destIcons | Out-Null
      Copy-Item -Force (Join-Path $IconDir '*.png') $destIcons
      $iconNote = " + $((Get-ChildItem $destIcons -Filter *.png).Count) icons"
    }
    # persist THIS script into the manifest repo (its durable home; no machine path is baked in)
    if ($PSCommandPath -and (Test-Path $PSCommandPath)) {
      Copy-Item -Force $PSCommandPath (Join-Path $mwork (Split-Path -Leaf $PSCommandPath))
    }
    Write-Utf8NoBom (Join-Path $mwork 'pluginmaster.json') $json
    git -C $mwork add -A 2>&1 | Out-Null
    git -C $mwork -c user.name='lilasrepo' -c user.email='lilasrepo@users.noreply.github.com' commit -m "manifest: refresh pluginmaster ($($entries.Count) plugins)$iconNote" 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
      $pushUrl = "https://$Account`:$token@github.com/$Account/$ManifestRepo.git"
      $o = git -C $mwork push $pushUrl HEAD:main 2>&1 | Out-String
      Write-Host ("  " + (Hide-Token $o $token).Trim())
      if ($LASTEXITCODE -ne 0) { throw "manifest push failed" }
      Gh repo edit "$Account/$ManifestRepo" --default-branch main | Out-Null
      Write-Host "  manifest pushed." -ForegroundColor Green
      Write-Host ("  RAW URL -> https://raw.githubusercontent.com/$Account/$ManifestRepo/main/pluginmaster.json") -ForegroundColor Cyan
    } else { Write-Host "  manifest unchanged" }
    Remove-Item -Recurse -Force $mwork -ErrorAction SilentlyContinue
  }
}

# ---------------------------------------------------------------------------- summary ----
Write-Host ""
Write-Host "================= summary =================" -ForegroundColor Cyan
if ($results) { $results | Format-Table -AutoSize | Out-String | Write-Host }
if ($staleWarnings.Count -gt 0) {
  Write-Host ("FROZEN-VERSION WARNING: {0} plugin(s) will NOT reach installed clients (same version re-clobbered): {1}" -f $staleWarnings.Count, ($staleWarnings -join ', ')) -ForegroundColor Red
  Write-Host  "  -> bump <Version> for each (or re-run /plugin_update so its Layer-2 auto-bump fires), then re-publish." -ForegroundColor Red
}
if ($DryRun) { Write-Host "DRY-RUN complete. Nothing was changed. Re-run with -Execute to apply." -ForegroundColor Yellow }
else         { Write-Host "DONE." -ForegroundColor Green }
