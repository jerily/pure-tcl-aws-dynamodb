# 
# Copyright Jerily LTD. All Rights Reserved.
# SPDX-FileCopyrightText: 2026 Neofytos Dimitriou (neo@jerily.cy)
# SPDX-License-Identifier: MIT.
# 

package require pure-tcl-aws-core 1.0.0
namespace eval ::aws::dynamodb {namespace path ::aws::core}
::aws::core::register dynamodb {put_item get_item delete_item query_items scan update_item create_table delete_table list_tables}

# Dispatch a DynamoDB JSON operation.
proc ::aws::dynamodb::call {client action fields {retry 0}} {json $client DynamoDB_20120810.$action $fields 1.0 $retry}

# Encode an AttributeValue while keeping DynamoDB numbers as decimal strings.
proc ::aws::dynamodb::attribute {spec} {
    if {[llength $spec] != 2} {error "attribute value must be a type/value pair"}
    lassign $spec type value
    switch -- $type {
        S - N {set encoded [list S $value]}
        B {set encoded [list S [binary encode base64 -maxlen 0 $value]]}
        BOOL - NULL {set encoded [list BOOL [boolean $value]]}
        M {set encoded [item $value]}
        L {set values {}; foreach v $value {lappend values [attribute $v]}; set encoded [list L $values]}
        SS - NS {set encoded [strings $value]}
        BS {set values {}; foreach v $value {lappend values [binary encode base64 -maxlen 0 $v]}; set encoded [strings $values]}
        default {error "unsupported DynamoDB attribute type: $type"}
    }
    return [list M [dict create $type $encoded]]
}

# Encode a dictionary of typed DynamoDB attributes.
proc ::aws::dynamodb::item {values} {
    set fields {}; dict for {k v} $values {dict set fields $k [attribute $v]}; return [list M $fields]
}

# Decode an AWS AttributeValue to the existing Tcl type/value notation.
proc ::aws::dynamodb::decode_attribute {value} {
    if {[dict size $value] != 1} {error "malformed DynamoDB attribute response"}
    dict for {type data} $value {
        switch -- $type {
            M {set data [decode_item $data]}
            L {set values {}; foreach v $data {lappend values [decode_attribute $v]}; set data $values}
            B {set data [binary decode base64 $data]}
            BS {set values {}; foreach v $data {lappend values [binary decode base64 $v]}; set data $values}
        }
        return [list $type $data]
    }
}

# Decode an AWS item without losing binary data or numeric precision.
proc ::aws::dynamodb::decode_item {value} {
    set out {}; foreach key [lsort [dict keys $value]] {dict set out $key [decode_attribute [dict get $value $key]]}; return $out
}

# Convert typed attributes to ordinary Tcl values; decimal strings remain exact.
proc ::aws::dynamodb::typed_item_to_simple {value} {
    set out {}; dict for {key spec} $value {dict set out $key [simple_attribute $spec]}; return $out
}

# Recursively remove DynamoDB type tags.
proc ::aws::dynamodb::simple_attribute {spec} {
    if {[llength $spec] != 2} {error "attribute value must be a type/value pair"}
    lassign $spec type value
    switch -- $type {
        M {return [typed_item_to_simple $value]}
        L {set out {}; foreach v $value {lappend out [simple_attribute $v]}; return $out}
        BOOL {return [boolean $value]}
        NULL {return {}}
        S - N - B - SS - NS - BS {return $value}
        default {error "unsupported DynamoDB attribute type: $type"}
    }
}

# Add validated conditional-write expressions to a request.
proc ::aws::dynamodb::conditions {fields optionsDict} {
    options $optionsDict {condition_expression expression_attribute_names expression_attribute_values}
    if {[dict exists $optionsDict condition_expression]} {dict set fields ConditionExpression [list S [dict get $optionsDict condition_expression]]}
    if {[dict exists $optionsDict expression_attribute_names]} {dict set fields ExpressionAttributeNames [stringmap [dict get $optionsDict expression_attribute_names]]}
    if {[dict exists $optionsDict expression_attribute_values]} {
        set values [dict get $optionsDict expression_attribute_values]
        dict for {k spec} $values {if {[lindex $spec 0] ni {S N BOOL}} {error "condition values support S, N and BOOL"}}
        dict set fields ExpressionAttributeValues [item $values]
    }
    return $fields
}

# Put a typed item, optionally guarded by a condition.
proc ::aws::dynamodb::_put_item {client table values {opts {}}} {
    call $client PutItem [conditions [dict create TableName [list S $table] Item [item $values]] $opts]
    return 1
}

# Return a typed item, or an empty dictionary when absent.
proc ::aws::dynamodb::_get_item {client table key {consistent {}}} {
    set fields [dict create TableName [list S $table] Key [item $key]]
    if {$consistent ne {}} {dict set fields ConsistentRead [list BOOL [boolean $consistent]]}
    set r [call $client GetItem $fields 1]
    return [decode_item [get $r Item]]
}

# Delete an item, optionally guarded by a condition.
proc ::aws::dynamodb::_delete_item {client table key {opts {}}} {
    call $client DeleteItem [conditions [dict create TableName [list S $table] Key [item $key]] $opts]
    return 1
}

# Execute an update expression and return the updated typed attributes.
proc ::aws::dynamodb::_update_item {client table key expression {opts {}}} {
    set fields [conditions [dict create TableName [list S $table] Key [item $key] UpdateExpression [list S $expression] ReturnValues {S ALL_NEW}] $opts]
    return [decode_item [get [call $client UpdateItem $fields] Attributes]]
}

# Follow item pages while enforcing an optional total item limit.
proc ::aws::dynamodb::pages {client action fields {limit 0}} {
    set out {}; set seen {}
    while {1} {
        if {$limit} {dict set fields Limit [list N [expr {$limit-[llength $out]}]]}
        set result [call $client $action $fields 1]
        foreach value [get $result Items] {
            lappend out [decode_item $value]
            if {$limit && [llength $out] >= $limit} {return $out}
        }
        set key [get $result LastEvaluatedKey]
        if {![next seen $key]} {return $out}
        dict set fields ExclusiveStartKey [item [decode_item $key]]
    }
}

# Query equality keys, retaining the legacy positional options and total limit.
proc ::aws::dynamodb::_query_items {client table keys {projection {}} {forward {}} {limit {}} {index {}} {consistent false}} {
    set fields [dict create TableName [list S $table] ConsistentRead [list BOOL [boolean $consistent]]]
    set expressions {}; set values {}
    dict for {key spec} $keys {
        if {![regexp {^[A-Za-z_][A-Za-z0-9_]*$} $key]} {error "query key names must be identifiers"}
        lappend expressions "$key = :$key"; dict set values :$key $spec
    }
    dict set fields KeyConditionExpression [list S [join $expressions { AND }]]
    dict set fields ExpressionAttributeValues [item $values]
    if {$projection ne {}} {dict set fields ProjectionExpression [list S $projection]}
    if {$forward ne {}} {dict set fields ScanIndexForward [list BOOL [boolean $forward]]}
    if {$index ne {}} {dict set fields IndexName [list S $index]}
    if {$limit eq {}} {set limit 0} else {integer $limit 1 2147483647 limit}
    return [pages $client Query $fields $limit]
}

# Scan all pages, optionally projecting selected attributes.
proc ::aws::dynamodb::_scan {client table {projection {}}} {
    set fields [dict create TableName [list S $table]]
    if {$projection ne {}} {dict set fields ProjectionExpression [list S $projection]}
    return [pages $client Scan $fields]
}

# Encode provisioned capacity with explicit positive integer validation.
proc ::aws::dynamodb::throughput {values} {
    options $values {ReadCapacityUnits WriteCapacityUnits}
    set out {}; foreach key {ReadCapacityUnits WriteCapacityUnits} {dict set out $key [list N [integer [required $values $key] 1 2147483647 $key]]}
    return [list M $out]
}

# Create an on-demand or provisioned table with optional global indexes.
proc ::aws::dynamodb::_create_table {client table schema {capacity {}} {indexes {}}} {
    set attrs {}; set keys {}
    dict for {name spec} $schema {
        if {[llength $spec] ni {1 2} || [lindex $spec 0] ni {S N B}} {error "invalid key schema definition"}
        lappend attrs [list M [dict create AttributeName [list S $name] AttributeType [list S [lindex $spec 0]]]]
        if {[llength $spec] == 2} {
            set type [string toupper [lindex $spec 1]]
            if {$type ni {HASH RANGE}} {error "key type must be HASH or RANGE"}
            lappend keys [list M [dict create AttributeName [list S $name] KeyType [list S $type]]]
        }
    }
    set fields [dict create TableName [list S $table] AttributeDefinitions [list L $attrs] KeySchema [list L $keys] BillingMode {S PAY_PER_REQUEST}]
    if {[dict size $capacity]} {dict set fields BillingMode {S PROVISIONED}; dict set fields ProvisionedThroughput [throughput $capacity]}
    set out {}
    foreach index $indexes {
        options $index {IndexName KeySchema ProvisionedThroughput}
        set ks {}
        foreach pair [required $index KeySchema] {
            if {[llength $pair] != 2 || [string toupper [lindex $pair 1]] ni {HASH RANGE}} {error "invalid index key schema"}
            lappend ks [list M [dict create AttributeName [list S [lindex $pair 0]] KeyType [list S [string toupper [lindex $pair 1]]]]]
        }
        set value [dict create IndexName [list S [required $index IndexName]] KeySchema [list L $ks] Projection {M {ProjectionType {S ALL}}}]
        if {[dict size $capacity]} {dict set value ProvisionedThroughput [throughput [get $index ProvisionedThroughput $capacity]]}
        lappend out [list M $value]
    }
    if {[llength $out]} {dict set fields GlobalSecondaryIndexes [list L $out]}
    call $client CreateTable $fields
    return 1
}

# Delete a table and return the legacy success boolean.
proc ::aws::dynamodb::_delete_table {client table} {call $client DeleteTable [dict create TableName [list S $table]]; return 1}

# Return table names across all pages.
proc ::aws::dynamodb::_list_tables {client} {
    set fields {}; set out {}; set seen {}
    while {1} {
        set page [call $client ListTables $fields 1]
        lappend out {*}[get $page TableNames]
        set token [get $page LastEvaluatedTableName]
        if {![next seen $token]} {return $out}
        dict set fields ExclusiveStartTableName [list S $token]
    }
}
package provide pure-tcl-aws-dynamodb 1.0.0
package provide awsdynamodb 1.0.19
