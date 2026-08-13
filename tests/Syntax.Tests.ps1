<#
    Mistakes PowerShell accepts at parse time and only complains about when the
    line finally runs. The window is full of code paths that no test can reach
    without WPF, so anything checkable from the syntax tree is worth checking
    here rather than discovering it in front of a user.
#>

$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

function Get-PowerShellFile {
    return @(Get-ChildItem -LiteralPath $repoRoot -Include '*.ps1', '*.psm1' -File -Recurse |
            Where-Object { $_.FullName -notlike "*$([System.IO.Path]::DirectorySeparatorChar).git$([System.IO.Path]::DirectorySeparatorChar)*" })
}

function Get-SwitchParameterName {
    <#
        Every switch parameter of every function defined in these files, so a
        call can be checked against the thing it is calling.
    #>
    param([System.Management.Automation.Language.Ast] $Ast)

    $map = @{}
    foreach ($function in $Ast.FindAll({
                param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
            }, $true)) {

        if ($function.Parameters) { $parameters = @($function.Parameters) }
        elseif ($function.Body.ParamBlock) { $parameters = @($function.Body.ParamBlock.Parameters) }
        else { $parameters = @() }

        $switches = foreach ($parameter in $parameters) {
            if ($parameter.StaticType -eq [System.Management.Automation.SwitchParameter]) {
                $parameter.Name.VariablePath.UserPath
            }
        }
        if (@($switches).Count) { $map[$function.Name] = @($switches) }
    }
    return $map
}

Describe 'Assignments that quietly change shape' {

    It 'never takes an array out of an if or a switch used as an expression' {
        # $x = if (...) { @(...) } has its output unrolled: a one-item array
        # comes back as the bare item and an empty one as $null. Under
        # Set-StrictMode, .Count on either is a terminating error, so a step with
        # exactly one file to copy failed and the window reported nothing but
        # "the property 'Count' cannot be found". Assign in each branch instead.
        $offences = [System.Collections.Generic.List[string]]::new()

        foreach ($file in (Get-PowerShellFile)) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)

            foreach ($assignment in $ast.FindAll({
                        param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst]
                    }, $true)) {

                $right = $assignment.Right
                # foreach used as an expression is idiomatic and its result is
                # wrapped where it is used; the trap is a branch that went to the
                # trouble of writing @( ), which says the author wanted an array
                # and will be surprised not to have one.
                $isStatement = $right -is [System.Management.Automation.Language.IfStatementAst] -or
                $right -is [System.Management.Automation.Language.SwitchStatementAst]
                if (-not $isStatement) { continue }

                # What the branch actually hands back, not whatever @( ) happens to
                # appear inside it: "{ @($x).Count }" returns a number and is fine.
                $bodies = [System.Collections.Generic.List[psobject]]::new()
                foreach ($clause in $right.Clauses) { $bodies.Add($clause.Item2) }
                if ($right.ElseClause) { $bodies.Add($right.ElseClause) }

                $yieldsArray = $false
                foreach ($body in $bodies) {
                    $statements = @($body.Statements)
                    if (-not $statements.Count) { continue }
                    $last = $statements[-1]
                    if ($last -isnot [System.Management.Automation.Language.PipelineAst]) { continue }
                    $elements = @($last.PipelineElements)
                    if ($elements.Count -ne 1) { continue }
                    if ($elements[0] -isnot [System.Management.Automation.Language.CommandExpressionAst]) { continue }
                    if ($elements[0].Expression -is [System.Management.Automation.Language.ArrayExpressionAst]) {
                        $yieldsArray = $true
                        break
                    }
                }
                if (-not $yieldsArray) { continue }

                $offences.Add(("{0}:{1} — {2}" -f $file.Name, $assignment.Extent.StartLineNumber,
                        ($assignment.Extent.Text -split "`n")[0].Trim()))
            }
        }

        Assert-Equal 0 $offences.Count ("An array is being taken out of a statement used as an expression, " +
            "which unrolls it — a single item stops being an array:`n  " + ($offences -join "`n  "))
    }
}

Describe 'Calls into our own functions' {

    It 'calls something that exists' {
        # A mistyped function name is a runtime error, and most of the window
        # never runs anywhere the suite can reach it.
        $offences = [System.Collections.Generic.List[string]]::new()

        # Commands that may or may not be installed. Each one is used behind a
        # check that it exists, so it cannot be resolved here and must not be
        # reported as a typo.
        $optional = @('Invoke-ScriptAnalyzer')

        # Gathered across every file first: the window's functions are called from
        # the tests that lift them out of it, and the module's from everywhere.
        $files = @(Get-PowerShellFile)
        $defined = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($file in $files) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
            foreach ($function in $ast.FindAll({
                        param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
                    }, $true)) {
                $null = $defined.Add($function.Name)
            }
        }

        foreach ($file in $files) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)

            foreach ($command in $ast.FindAll({
                        param($node) $node -is [System.Management.Automation.Language.CommandAst]
                    }, $true)) {

                $name = $command.GetCommandName()
                # A name built from a variable cannot be checked from here.
                if (-not $name -or $name -match '[$]') { continue }
                if ($defined.Contains($name)) { continue }
                if ($optional -contains $name) { continue }
                if (Get-Command -Name $name -ErrorAction SilentlyContinue) { continue }

                $offences.Add(("{0}:{1} — nothing called {2}" -f $file.Name, $command.Extent.StartLineNumber, $name))
            }
        }

        Assert-Equal 0 $offences.Count ("A call goes to something that does not exist:`n  " + ($offences -join "`n  "))
    }

    It 'passes switch values with a colon, not a space' {
        # -Blocked $false does not set the switch to false. PowerShell reads the
        # switch as present and $false as a positional argument, which an
        # advanced function rejects with "a positional parameter cannot be
        # found". -Blocked:$false is the form that means what it looks like.
        $offences = [System.Collections.Generic.List[string]]::new()

        foreach ($file in (Get-PowerShellFile)) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
            $switchesByFunction = Get-SwitchParameterName -Ast $ast

            foreach ($command in $ast.FindAll({
                        param($node) $node -is [System.Management.Automation.Language.CommandAst]
                    }, $true)) {

                $name = $command.GetCommandName()
                if (-not $name -or -not $switchesByFunction.ContainsKey($name)) { continue }
                $switches = $switchesByFunction[$name]

                $elements = @($command.CommandElements)
                for ($i = 1; $i -lt $elements.Count; $i++) {
                    $element = $elements[$i]
                    if ($element -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
                    if ($switches -notcontains $element.ParameterName) { continue }
                    # -Switch:$value keeps the value on the parameter itself.
                    if ($null -ne $element.Argument) { continue }

                    $next = if ($i + 1 -lt $elements.Count) { $elements[$i + 1] } else { $null }
                    if ($null -eq $next) { continue }
                    if ($next -is [System.Management.Automation.Language.CommandParameterAst]) { continue }

                    $offences.Add(("{0}:{1} — {2} -{3} {4}" -f $file.Name, $element.Extent.StartLineNumber,
                            $name, $element.ParameterName, $next.Extent.Text))
                }
            }
        }

        Assert-Equal 0 $offences.Count ("A switch is being given a value with a space, which does not do what it looks like:`n  " +
            ($offences -join "`n  "))
    }

    It 'names a parameter that the function it calls actually has' {
        # A renamed parameter with a caller left behind is another thing that
        # only shows up when that line runs.
        $offences = [System.Collections.Generic.List[string]]::new()

        foreach ($file in (Get-PowerShellFile)) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)

            $known = @{}
            foreach ($function in $ast.FindAll({
                        param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
                    }, $true)) {
                $parameters = if ($function.Parameters) { $function.Parameters }
                elseif ($function.Body.ParamBlock) { $function.Body.ParamBlock.Parameters }
                else { $null }
                # A function with no param block takes $args and cannot be checked.
                if ($null -eq $parameters) { continue }
                $known[$function.Name] = @($parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
            }

            foreach ($command in $ast.FindAll({
                        param($node) $node -is [System.Management.Automation.Language.CommandAst]
                    }, $true)) {
                $name = $command.GetCommandName()
                if (-not $name -or -not $known.ContainsKey($name)) { continue }

                foreach ($element in $command.CommandElements) {
                    if ($element -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
                    $parameterName = $element.ParameterName
                    # Common parameters are always available on advanced functions.
                    if ($parameterName -in @('Verbose', 'Debug', 'ErrorAction', 'WarningAction', 'InformationAction',
                            'ErrorVariable', 'WarningVariable', 'InformationVariable', 'OutVariable',
                            'OutBuffer', 'PipelineVariable', 'WhatIf', 'Confirm')) { continue }

                    # Parameter names may be abbreviated, so a prefix match counts.
                    $matched = @($known[$name] | Where-Object { $_ -like "$parameterName*" })
                    if (-not $matched.Count) {
                        $offences.Add(("{0}:{1} — {2} has no -{3}" -f $file.Name, $element.Extent.StartLineNumber, $name, $parameterName))
                    }
                }
            }
        }

        Assert-Equal 0 $offences.Count ("A call names a parameter its function does not have:`n  " + ($offences -join "`n  "))
    }
}
