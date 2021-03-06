<#
.SYNOPSIS
    Convert a PowerShell object to a CSON (Coffee Script) representation in a string.
.DESCRIPTION
    Converts a PowerShell object to a CSON (Coffee Script) notation as a string.
.PARAMETER InputObject
    The input PowerShell object to be represented in a CSON notation.  This parameter may be received from the pipeline.
.PARAMETER Indent
    Specifies a string value to be used for each level of the indention within the CSON document.
.PARAMETER Depth
    Specifies the maximum depth of recursion permitted for the input object.
.PARAMETER EnumsAsStrings
    A switch that specifies an alternate serialization option that converts all enumerations to their string representations.
.EXAMPLE
    $grammar_json | ConvertTo-Cson -Indent `t -Depth 100 | Set-Content out\PowerShell.cson -Encoding UTF8
.INPUTS
    [object] - any PowerShell object.
.OUTPUTS
    [string] - the input object returned in a CSON notation.
.NOTES
    Script / Function / Class assembled by Carl Morris, Morris Softronics, Hooper, NE, USA
    Initial release - Mar 3, 2019
.LINK
    https://github.com/msftrncs/PwshOutCSON/
.FUNCTIONALITY
    data format conversion
#>
function ConvertTo-Cson {
    param(
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [AllowNull()]
        [object]$InputObject,

        [PSDefaultValue(Help = 'Tab')]
        [string]$Indent = "`t",

        [ValidateRange(1, 100)]
        [int32]$Depth = 2,

        [switch]$EnumsAsStrings
    )
    # write out a CSON document from the object supplied
    # $InputObject is an object, who's properties will be output as CSON.  Hash tables are supported.
    # $Indent is a string representing the indentation to use.
    #   Typically use "`t" or "  ".

    # define a match evaluator for escaping characters
    $escape_replacer = {
        switch ($_) {
            { $_.Groups[1].Success } {
                # group 1, control characters
                switch ($_.Value[0]) {
                    <# appearing in order of expected frequency, from most frequent to least frequent #>
                    ([char]10) { '\n'; continue } # new line
                    ([char]9) { '\t'; continue }  # tab
                    ([char]13) { '\r'; continue } # caridge return
                    ([char]12) { '\f'; continue } # new form
                    ([char]8) { '\b'; continue }  # bell
                    default { '\u{0:X4}' -f [int16]$_ }   # unicode escape all others
                }
                continue
            }
            { $_.Groups[2].Success } {
                # group 2, items that need `\` escape
                "\$($_.Value)"
            }
        }
    }

    filter writeStringValue {
        # write an escaped CSON string property value
        # the purpose of making this a function, is a single place to change the escaping function used
        # TODO: escape more characters!
        """$($_ -replace '([\x00-\x1F\x85\u2028\u2029])|([\\"]|#\{)', $escape_replacer)"""
    }

    function writeProperty ([string]$name, $item, [string]$indention, [int32]$level) {
        # writing the property may require recursively breaking down the objects based on their type
        # name of the property is optional, but that is only intended for the first property object

        function writeValue ($item, [string]$indention) {
            # write a property value
            "$indention$(
                if (($item -is [string]) -or ($item -is [char]) -or (($item -is [enum]) -and $EnumsAsStrings) -or ($level -ge $Depth)) {
                    # handle strings or characters, or objects exceeding the max depth
                    "$item" | writeStringValue
                }
                elseif ($item -is [boolean]) {
                    # handle boolean type
                    if ($item) {
                        'true'
                    }
                    else {
                        'false'
                    }
                } 
                elseif ($item -is [datetime]) {
                    # specifically format date/time to ISO 8601
                    $item.ToString('o') | writeStringValue
                } 
                elseif ($item -isnot [enum]) {
                    # assuming a [valuetype] that doesn't need special treatment
                    $item
                } 
                else {
                    # specifically out the enum value
                    $item.value__
                }
            )"
        }

        # write out key name, if one was supplied from the parent object
        if ($name) {
            "$indention$(
                # if a property name is not all simple characters or start with numeric digit, it must be quoted and escaped
                if ($name -match '[^\p{L}\d_]|^\d') {
                    # property name requires escaping
                    $name | writeStringValue
                }
                else {
                    $name
                }
            ):$(
                if (($item -is [array]) -and ($level -lt $Depth)) {
                    ' [' # add array start token if property is an array
                }
                elseif (($item -is [ValueType]) -or ($item -is [string]) -or ($level -ge $Depth)) {
                    " $(writeValue $item '')"
                }
            )"
        }
        else {
            if (($item -is [array]) -and ($level -lt $Depth)) {
                "$indention[" # add array start token if property is an array
            }
            elseif (($item -is [valuetype]) -or ($item -is [string]) -or ($level -ge $Depth)) {
                writeValue $item "$indention"
            }
        }

        if ($level -lt $Depth) {
            if ($item -is [array]) {
                # handle arrays, iterate through the items in the array
                foreach ($subitem in $item) {
                    if (($subitem -is [valuetype]) -or ($subitem -is [string])) {
                        writeValue $subitem "$indention$Indent"
                    }
                    elseif ($subitem -is [array]) {
                        writeProperty '' $subitem "$indention$Indent" ($level + 1)
                    }
                    else {
                        "$indention$indent{"
                        writeProperty '' $subitem "$indention$Indent" ($level + 1)
                        "$indention$Indent}"
                    }
                }
                "$indention]"
            }
            elseif ($item -isnot [valuetype] -and $item -isnot [string]) {
                # handle objects by recursing with writeProperty
                if ($item.GetType().Name -in 'HashTable', 'OrderedDictionary') {
                    # process what we assume is a hashtable object
                    foreach ($hash in $item.GetEnumerator()) {
                        writeProperty $hash.Key $hash.Value $(if ($level -ge 0) { "$indention$Indent" } else { $indention }) ($level + 1)
                    }
                } else {
                    # iterate through the items (force to a PSCustomObject for consistency)
                    foreach ($property in ([PSCustomObject]$item).psobject.Properties) {
                        writeProperty $property.Name $property.Value $(if ($level -ge 0) { "$indention$Indent" } else { $indention }) ($level + 1)
                    }
                }
            }
        }
    }

    # start writing the property list, the property list should be an object, has no name, and starts at base level
    (writeProperty '' $InputObject '' (-1)) -join $(if (-not $IsCoreCLR -or $IsWindows) { "`r`n" } else { "`n" })
}
