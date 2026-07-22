BeforeAll {
    . (Join-Path $PSScriptRoot 'Manifest.Helpers.ps1')
    $script:manifest = Get-AgentManifest
    $script:agents   = $script:manifest.agents
    $script:byId     = @{}
    foreach ($a in $script:agents) { $script:byId[$a.id] = $a }
    $script:names    = @($script:agents.displayName)
}

Describe 'Hierarchy - parent references' {
    It 'exactly one root (parent = null) which is the master' {
        $roots = @($script:agents | Where-Object { $null -eq $_.parent })
        $roots.Count | Should -Be 1
        $roots[0].id | Should -Be 'fabric-workspace-master'
    }

    It 'every non-null parent resolves to an existing agent id' {
        foreach ($a in $script:agents | Where-Object { $null -ne $_.parent }) {
            $script:byId.ContainsKey($a.parent) | Should -BeTrue -Because "parent '$($a.parent)' of '$($a.id)' must exist"
        }
    }

    It 'the parent chain has no cycles and reaches the master' {
        foreach ($a in $script:agents) {
            $seen = @{}
            $cur = $a
            while ($null -ne $cur.parent) {
                $seen.ContainsKey($cur.id) | Should -BeFalse -Because "cycle detected at '$($cur.id)'"
                $seen[$cur.id] = $true
                $cur = $script:byId[$cur.parent]
            }
            $cur.id | Should -Be 'fabric-workspace-master'
        }
    }
}

Describe 'Hierarchy - delegation (allowedChildren)' {
    It 'every allowedChildren entry resolves to an existing display name' {
        foreach ($a in $script:agents) {
            foreach ($child in $a.allowedChildren) {
                $script:names -contains $child | Should -BeTrue -Because "'$($a.id)' delegates to unknown '$child'"
            }
        }
    }

    It 'only agents that hold the "agent" tool may delegate' {
        foreach ($a in $script:agents) {
            $effectiveTools = if ($a.tools) { $a.tools } else { $script:manifest.defaults.tools }
            if (@($a.allowedChildren).Count -gt 0) {
                $effectiveTools -contains 'agent' | Should -BeTrue -Because "'$($a.id)' delegates but lacks the 'agent' tool"
            }
        }
    }

    It 'workers do not delegate (no allowedChildren)' {
        foreach ($w in $script:agents | Where-Object level -eq 'worker') {
            @($w.allowedChildren).Count | Should -Be 0 -Because "worker '$($w.id)' must not delegate"
        }
    }

    It 'the master can reach every team-lead and executive reviewer' {
        $master = $script:byId['fabric-workspace-master']
        foreach ($lead in $script:agents | Where-Object { $_.level -eq 'team-lead' }) {
            $master.allowedChildren -contains $lead.displayName | Should -BeTrue -Because "master must list lead '$($lead.displayName)'"
        }
    }
}

Describe 'Hierarchy - visibility invariants' {
    It 'executives and team-leads are visible and user-invocable' {
        foreach ($a in $script:agents | Where-Object { $_.level -in @('executive','team-lead') }) {
            $a.visibility    | Should -Be 'visible'
            $a.userInvocable | Should -BeTrue
        }
    }

    It 'workers are hidden and not user-invocable' {
        foreach ($w in $script:agents | Where-Object level -eq 'worker') {
            $w.visibility    | Should -Be 'hidden'
            $w.userInvocable | Should -BeFalse
        }
    }
}
