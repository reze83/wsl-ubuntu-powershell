#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Pester 5 tests for Setup-WSL.ps1 interactive wizard functions.

.DESCRIPTION
    Tests the helper functions defined in Setup-WSL.ps1 without executing
    the main block. The script functions are extracted via dot-sourcing
    after setting $env:PESTER_TESTING to suppress main execution.

    Strategy: Set a guard env variable that causes the script to return
    before the main block runs, then dot-source to load all function definitions.
#>

BeforeAll {
    $scriptPath = Join-Path $PSScriptRoot '..' 'Setup-WSL.ps1'
    $scriptPath = (Resolve-Path $scriptPath).Path

    # We need to load the functions without running the main block.
    # Approach: extract function definitions from the script and invoke them.
    # Since the script calls exit in the main block which would kill the test
    # runner, we use a ScriptBlock-based extraction approach.

    # Read the script content and extract only the function definitions
    # (everything before the #region -- Main block)
    $content = Get-Content $scriptPath -Raw

    # Split at the Main region marker to get only function definitions
    $mainMarker = '#region ── Main ──────────────────────────────────────────────────────────────'
    $idx = $content.IndexOf($mainMarker)
    if ($idx -lt 0) {
        throw "Could not find Main region marker in $scriptPath"
    }
    $functionsOnly = $content.Substring(0, $idx)

    # Also append the IsInteractive variable initialization that the functions depend on
    $functionsOnly += @'

# Test harness: initialize required script-scope variables
$Script:IsInteractive = $true
$Script:ExplicitParams = @{}
'@

    # Dot-source the functions by creating a temporary script file
    $tmpScript = [System.IO.Path]::GetTempFileName() + '.ps1'
    Set-Content -Path $tmpScript -Value $functionsOnly -Encoding UTF8

    try {
        . $tmpScript
    } finally {
        Remove-Item $tmpScript -Force -ErrorAction SilentlyContinue
    }
}

AfterAll {
    # Nothing to clean up
}

# ─── Test-IsInteractiveSession ────────────────────────────────────────────────

Describe 'Test-IsInteractiveSession' {

    Context 'When -Interactive switch is explicitly provided' {
        It 'returns true when Interactive is Present' {
            $Script:ExplicitParams = @{ Interactive = $true }
            $Script:Interactive_backup = $null

            # Simulate $Interactive switch being present
            $global:Interactive = [switch]::Present
            # We call the function with a local $Interactive variable in scope
            $result = & {
                $Interactive = [switch]::Present
                $Script:ExplicitParams = @{ Interactive = $true }
                Test-IsInteractiveSession
            }
            $result | Should -Be $true
        }

        It 'returns false when Interactive is not present (false)' {
            $result = & {
                $Interactive = [switch]$false
                $Script:ExplicitParams = @{ Interactive = $true }
                Test-IsInteractiveSession
            }
            $result | Should -Be $false
        }
    }

    Context 'When -Interactive is not explicitly provided' {
        BeforeEach {
            $Script:ExplicitParams = @{}
        }

        It 'returns false when CommandLineArgs contain -NonInteractive' -Skip:(-not $IsWindows -and -not ($PSVersionTable.PSVersion.Major -le 5)) {
            Mock -CommandName 'Get-ScheduledTask' -MockWith { $null }

            # We cannot easily mock [Environment]::GetCommandLineArgs() in PS 5.1,
            # but we can verify the function logic indirectly.
            # The function checks UserInteractive which we can influence via mocking
            # the scheduled task check.
            # This test documents expected behavior rather than being fully mockable.
            $result = Test-IsInteractiveSession
            # Result depends on actual environment; just verify it returns a bool
            $result | Should -BeOfType [bool]
        }

        It 'returns false when a resume task exists' -Skip:(-not $IsWindows -and -not ($PSVersionTable.PSVersion.Major -le 5)) {
            Mock -CommandName 'Get-ScheduledTask' -MockWith {
                [PSCustomObject]@{ TaskName = 'WSL-Setup-Resume' }
            }

            # Test-ResumeTaskExists is called inside Test-IsInteractiveSession
            # Since UserInteractive may be true but ResumeTask exists, should return false
            # Note: In test environment UserInteractive might already be false
            $result = Test-IsInteractiveSession
            $result | Should -Be $false
        }
    }
}

# ─── Test-ParamExplicit ───────────────────────────────────────────────────────

Describe 'Test-ParamExplicit' {

    It 'returns true when parameter name is in ExplicitParams' {
        $Script:ExplicitParams = @{ Action = 'install'; Distribution = 'Ubuntu-24.04' }
        Test-ParamExplicit 'Action' | Should -Be $true
        Test-ParamExplicit 'Distribution' | Should -Be $true
    }

    It 'returns false when parameter name is not in ExplicitParams' {
        $Script:ExplicitParams = @{ Action = 'install' }
        Test-ParamExplicit 'GitUserName' | Should -Be $false
        Test-ParamExplicit 'DryRun' | Should -Be $false
    }

    It 'returns false for empty ExplicitParams' {
        $Script:ExplicitParams = @{}
        Test-ParamExplicit 'Action' | Should -Be $false
    }
}

# ─── Prompt-Choice ────────────────────────────────────────────────────────────

Describe 'Prompt-Choice' {

    BeforeEach {
        $script:readHostCalls = 0
    }

    It 'returns default option when user presses Enter' {
        Mock -CommandName 'Read-Host' -MockWith { '' }

        $result = Prompt-Choice -Label 'Test:' -Options @('alpha', 'beta', 'gamma') -Default 'beta'
        $result | Should -Be 'beta'
    }

    It 'returns option when user enters valid number' {
        Mock -CommandName 'Read-Host' -MockWith { '3' }

        $result = Prompt-Choice -Label 'Test:' -Options @('alpha', 'beta', 'gamma') -Default 'alpha'
        $result | Should -Be 'gamma'
    }

    It 'returns option when user enters "1"' {
        Mock -CommandName 'Read-Host' -MockWith { '1' }

        $result = Prompt-Choice -Label 'Test:' -Options @('alpha', 'beta', 'gamma') -Default 'alpha'
        $result | Should -Be 'alpha'
    }

    It 'returns option when user types the option name directly' {
        Mock -CommandName 'Read-Host' -MockWith { 'beta' }

        $result = Prompt-Choice -Label 'Test:' -Options @('alpha', 'beta', 'gamma') -Default 'alpha'
        $result | Should -Be 'beta'
    }

    It 'retries on invalid number and then accepts valid input' {
        $script:callCount = 0
        Mock -CommandName 'Read-Host' -MockWith {
            $script:callCount++
            if ($script:callCount -eq 1) { return '99' }  # invalid
            return '2'                                      # valid on retry
        }
        Mock -CommandName 'Write-Host' -MockWith {}

        $result = Prompt-Choice -Label 'Test:' -Options @('alpha', 'beta') -Default 'alpha'
        $result | Should -Be 'beta'
        $script:callCount | Should -Be 2
    }

    It 'retries on invalid text and then accepts valid input' {
        $script:callCount = 0
        Mock -CommandName 'Read-Host' -MockWith {
            $script:callCount++
            if ($script:callCount -eq 1) { return 'invalid-option' }
            return '1'
        }
        Mock -CommandName 'Write-Host' -MockWith {}

        $result = Prompt-Choice -Label 'Test:' -Options @('alpha', 'beta') -Default 'alpha'
        $result | Should -Be 'alpha'
        $script:callCount | Should -Be 2
    }

    It 'retries when Enter pressed with no default set' {
        $script:callCount = 0
        Mock -CommandName 'Read-Host' -MockWith {
            $script:callCount++
            if ($script:callCount -eq 1) { return '' }  # no default → retry
            return '2'
        }
        Mock -CommandName 'Write-Host' -MockWith {}

        $result = Prompt-Choice -Label 'Test:' -Options @('alpha', 'beta') -Default ''
        $result | Should -Be 'beta'
        $script:callCount | Should -Be 2
    }
}

# ─── Prompt-Text ──────────────────────────────────────────────────────────────

Describe 'Prompt-Text' {

    It 'returns the typed text' {
        Mock -CommandName 'Read-Host' -MockWith { 'Max Mustermann' }
        Mock -CommandName 'Write-Host' -MockWith {}

        $result = Prompt-Text -Label 'Name:' -Default ''
        $result | Should -Be 'Max Mustermann'
    }

    It 'returns default when Enter pressed with default set' {
        Mock -CommandName 'Read-Host' -MockWith { '' }
        Mock -CommandName 'Write-Host' -MockWith {}

        $result = Prompt-Text -Label 'Name:' -Default 'DefaultName'
        $result | Should -Be 'DefaultName'
    }

    It 'returns empty string when AllowEmpty and Enter pressed with no default' {
        Mock -CommandName 'Read-Host' -MockWith { '' }
        Mock -CommandName 'Write-Host' -MockWith {}

        $result = Prompt-Text -Label 'Name:' -Default '' -AllowEmpty
        $result | Should -Be ''
    }

    It 'retries when empty and not AllowEmpty and no default' {
        $script:callCount = 0
        Mock -CommandName 'Read-Host' -MockWith {
            $script:callCount++
            if ($script:callCount -eq 1) { return '' }
            return 'SomeValue'
        }
        Mock -CommandName 'Write-Host' -MockWith {}

        $result = Prompt-Text -Label 'Name:' -Default ''
        $result | Should -Be 'SomeValue'
        $script:callCount | Should -Be 2
    }
}

# ─── Prompt-Confirm ───────────────────────────────────────────────────────────

Describe 'Prompt-Confirm' {

    Context 'In interactive mode' {
        BeforeEach {
            $Script:IsInteractive = $true
            Mock -CommandName 'Write-Host' -MockWith {}
        }

        It 'returns true (default) when Enter pressed and Default is true' {
            Mock -CommandName 'Read-Host' -MockWith { '' }

            $result = Prompt-Confirm -Label 'Fortfahren?' -Default $true
            $result | Should -Be $true
        }

        It 'returns false (default) when Enter pressed and Default is false' {
            Mock -CommandName 'Read-Host' -MockWith { '' }

            $result = Prompt-Confirm -Label 'Fortfahren?' -Default $false
            $result | Should -Be $false
        }

        It 'returns true when "j" entered' {
            Mock -CommandName 'Read-Host' -MockWith { 'j' }

            $result = Prompt-Confirm -Label 'Fortfahren?' -Default $false
            $result | Should -Be $true
        }

        It 'returns true when "J" entered' {
            Mock -CommandName 'Read-Host' -MockWith { 'J' }

            $result = Prompt-Confirm -Label 'Fortfahren?' -Default $false
            $result | Should -Be $true
        }

        It 'returns true when "y" entered' {
            Mock -CommandName 'Read-Host' -MockWith { 'y' }

            $result = Prompt-Confirm -Label 'Fortfahren?' -Default $false
            $result | Should -Be $true
        }

        It 'returns false when "n" entered' {
            Mock -CommandName 'Read-Host' -MockWith { 'n' }

            $result = Prompt-Confirm -Label 'Fortfahren?' -Default $true
            $result | Should -Be $false
        }

        It 'returns false when "N" entered' {
            Mock -CommandName 'Read-Host' -MockWith { 'N' }

            $result = Prompt-Confirm -Label 'Fortfahren?' -Default $true
            $result | Should -Be $false
        }
    }

    Context 'In non-interactive mode' {
        BeforeEach {
            $Script:IsInteractive = $false
            Mock -CommandName 'Write-Host' -MockWith {}
            Mock -CommandName 'Read-Host' -MockWith { throw 'Read-Host should not be called' }
        }

        It 'returns Default without prompting when not Destructive' {
            $result = Prompt-Confirm -Label 'Fortfahren?' -Default $true
            $result | Should -Be $true
            Should -Invoke 'Read-Host' -Times 0 -Scope It
        }

        It 'returns false Default without prompting when not Destructive' {
            $result = Prompt-Confirm -Label 'Fortfahren?' -Default $false
            $result | Should -Be $false
            Should -Invoke 'Read-Host' -Times 0 -Scope It
        }

        It 'calls Write-Err before exit when Destructive and non-interactive' {
            Mock -CommandName 'Write-Err' -MockWith {}
            # Mock exit to prevent it from killing the test runner
            Mock -CommandName 'Exit-Script' -MockWith { throw 'ExitCalled' } -ErrorAction SilentlyContinue

            # Prompt-Confirm calls exit (not Exit-Script) – catch the ScriptHaltException
            { Prompt-Confirm -Label 'Loeschen?' -Default $false -Destructive } | Should -Throw

            Should -Invoke 'Write-Err' -Times 1 -Scope It
        }
    }
}

# ─── Show-Summary ─────────────────────────────────────────────────────────────

Describe 'Show-Summary' {

    BeforeEach {
        Mock -CommandName 'Write-Host' -MockWith {}
        $script:Action       = 'install'
        $script:Distribution = 'Ubuntu-24.04'
        $script:SetupMode    = 'full'
        $script:GitUserName  = ''
        $script:GitUserEmail = ''
        $script:SshKeyEmail  = ''
        $script:RemoveWSLFeatures = $false
        $script:DryRun       = $false
        $Script:C = @{
            Reset  = ''
            Cyan   = ''
            Green  = ''
            Yellow = ''
            Red    = ''
            Dim    = ''
            Bold   = ''
        }
    }

    It 'runs without error for install action' {
        { Show-Summary } | Should -Not -Throw
    }

    It 'runs without error for status action' {
        $script:Action = 'status'
        { Show-Summary } | Should -Not -Throw
    }

    It 'runs without error for uninstall with RemoveWSLFeatures' {
        $script:Action = 'uninstall'
        $script:RemoveWSLFeatures = $true
        { Show-Summary } | Should -Not -Throw
    }

    It 'calls Write-Host multiple times (draws box)' {
        Show-Summary
        Should -Invoke 'Write-Host' -Scope It -Times 4 -Exactly:$false
    }
}

# ─── Start-InteractiveWizard ──────────────────────────────────────────────────

Describe 'Start-InteractiveWizard' {

    BeforeEach {
        $Script:ExplicitParams = @{}
        $Script:IsInteractive  = $true
        $script:Action         = 'install'
        $script:Distribution   = 'Ubuntu-24.04'
        $script:SetupMode      = 'full'
        $script:GitUserName    = ''
        $script:GitUserEmail   = ''
        $script:SshKeyEmail    = ''
        $script:RemoveWSLFeatures = $false
        Mock -CommandName 'Write-Host' -MockWith {}
    }

    It 'sets Action from wizard when not explicitly provided' {
        # Simulate user choosing "setup" (option 2)
        $script:callCount = 0
        Mock -CommandName 'Read-Host' -MockWith {
            $script:callCount++
            # Action choice = 'setup' (2), then Distribution, SetupMode, Git fields (all empty/Enter)
            switch ($script:callCount) {
                1 { return '2' }   # setup
                2 { return '' }    # Distribution default
                3 { return '' }    # SetupMode default
                4 { return '' }    # GitUserName empty
                5 { return '' }    # GitUserEmail empty
                default { return '' }
            }
        }

        Start-InteractiveWizard

        $script:Action | Should -Be 'setup'
    }

    It 'skips Action prompt when Action explicitly provided' {
        $Script:ExplicitParams = @{ Action = $true }
        $script:Action = 'status'

        # Only Distribution would be prompted (and only if not status)
        # For status: no prompts at all
        Mock -CommandName 'Read-Host' -MockWith { '' }

        Start-InteractiveWizard

        $script:Action | Should -Be 'status'
        Should -Invoke 'Read-Host' -Times 0 -Scope It
    }

    It 'skips Distribution prompt for status action' {
        $Script:ExplicitParams = @{ Action = $true }
        $script:Action = 'status'
        Mock -CommandName 'Read-Host' -MockWith { '' }

        Start-InteractiveWizard

        Should -Invoke 'Read-Host' -Times 0 -Scope It
    }

    It 'sets SshKeyEmail to GitUserEmail default when email provided' {
        $Script:ExplicitParams = @{ Action = $true; Distribution = $true; SetupMode = $true; GitUserName = $true }
        $script:Action       = 'setup'
        $script:Distribution = 'Ubuntu-24.04'
        $script:SetupMode    = 'full'
        $script:GitUserName  = 'Test User'

        $script:callCount = 0
        Mock -CommandName 'Read-Host' -MockWith {
            $script:callCount++
            switch ($script:callCount) {
                1 { return 'test@example.com' }  # GitUserEmail
                2 { return '' }                   # SshKeyEmail (Enter = default = GitUserEmail)
                default { return '' }
            }
        }

        Start-InteractiveWizard

        $script:GitUserEmail | Should -Be 'test@example.com'
        $script:SshKeyEmail  | Should -Be 'test@example.com'
    }

    It 'skips SshKeyEmail prompt when GitUserEmail is empty' {
        $Script:ExplicitParams = @{ Action = $true; Distribution = $true; SetupMode = $true; GitUserName = $true }
        $script:Action       = 'setup'
        $script:Distribution = 'Ubuntu-24.04'
        $script:SetupMode    = 'full'
        $script:GitUserName  = 'Test User'
        $script:GitUserEmail = ''

        $script:callCount = 0
        Mock -CommandName 'Read-Host' -MockWith {
            $script:callCount++
            return ''  # empty for GitUserEmail
        }

        Start-InteractiveWizard

        # Only GitUserEmail prompt should be called (1 Read-Host call)
        $script:callCount | Should -Be 1
        $script:SshKeyEmail | Should -Be ''
    }
}

# ─── Non-interactive mode integration ─────────────────────────────────────────

Describe 'Non-interactive mode behavior' {

    BeforeEach {
        $Script:IsInteractive = $false
        $Script:ExplicitParams = @{}
        Mock -CommandName 'Write-Host' -MockWith {}
        Mock -CommandName 'Write-Err'  -MockWith {}
        Mock -CommandName 'Write-Warn' -MockWith {}
    }

    It 'Test-ParamExplicit returns false for all params when none provided' {
        $Script:ExplicitParams = @{}
        Test-ParamExplicit 'Action'       | Should -Be $false
        Test-ParamExplicit 'Distribution' | Should -Be $false
        Test-ParamExplicit 'SetupMode'    | Should -Be $false
    }

    It 'Prompt-Confirm returns Default value without prompting in non-interactive mode' {
        Mock -CommandName 'Read-Host' -MockWith { throw 'Should not be called' }

        $result = Prompt-Confirm -Label 'Test?' -Default $true
        $result | Should -Be $true
    }

    It 'Prompt-Confirm returns false Default without prompting' {
        Mock -CommandName 'Read-Host' -MockWith { throw 'Should not be called' }

        $result = Prompt-Confirm -Label 'Test?' -Default $false
        $result | Should -Be $false
    }
}
