@{
    Severity = @('Error', 'Warning')
    ExcludeRules = @(
        # Human-readable CLI mode intentionally uses host colors; JSON mode does not.
        'PSAvoidUsingWriteHost'

        # These are private script helpers, not exported PowerShell commands.
        'PSUseApprovedVerbs'
        'PSUseSingularNouns'
        'PSUseShouldProcessForStateChangingFunctions'
        'PSShouldProcess'

        # Script parameters and dot-sourced variables are consumed by nested functions/callers.
        'PSReviewUnusedParameter'
        'PSUseDeclaredVarsMoreThanAssignments'

        # Global sentinels are confined to caller-overwrite tests.
        'PSAvoidGlobalVars'
    )
}
