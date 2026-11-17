# pure-tcl-aws-dynamodb

AWS DYNAMODB client implemented in Tcl 9.1. Its only package dependency is
[`pure-tcl-aws-core`](https://github.com/jerily/pure-tcl-aws-core), which supplies
HTTP, JSON, XML, credentials and signing. No AWS C++ SDK is required.

```tcl
package require pure-tcl-aws-dynamodb 1.0.0
set client [::aws::dynamodb::create {region us-east-1}]
try {
    puts [$client list_tables]
} finally {
    $client destroy
}
```

`package require awsdynamodb 1.0.19` is also supported. Use one implementation
of the `awsdynamodb` package per interpreter. Existing namespace commands
(`::aws::dynamodb::method $client ...`) and client methods share the same behavior.
Client destruction returns an empty result. Unknown methods and invalid arguments
raise Tcl errors. See the core README for credentials, configuration and retries.

## Methods

| Method | Arguments after the client handle |
| --- | --- |
| `put_item` | `table values ?opts?` |
| `get_item` | `table key ?consistent?` |
| `delete_item` | `table key ?opts?` |
| `update_item` | `table key expression ?opts?` |
| `query_items` | `table keys ?projection? ?forward? ?limit? ?index? ?consistent?` |
| `scan` | `table ?projection?` |
| `create_table` | `table schema ?capacity? ?indexes?` |
| `delete_table` | `table` |
| `list_tables` | — |

`::aws::dynamodb::typed_item_to_simple $item` removes attribute type tags.

## Behavior

Attributes use `{type value}` pairs, including recursive `M` and `L`, binary `B`, sets, `BOOL` and `NULL`. DynamoDB numbers remain decimal strings so precision is preserved. Query limits cap the total number of returned items across pages. Conditions preserve the existing scalar `S`, `N` and `BOOL` interface. `update_item table key expression ?options?` implements the previously unimplemented method and returns the updated typed attributes.

## Install and examples

Install the core and its dependencies first, then run:

```sh
make install PREFIX=/your/prefix
```

The release recipe declares examples with `file` entries. After registry installation:

```sh
ttrek run -package pure-tcl-aws-dynamodb -script example-list-tables
ttrek run -package pure-tcl-aws-dynamodb -script example-get-item -- table key-name key-value
```

`./run-example.sh --help` lists arguments. Set AWS credentials and `AWS_REGION`
or `AWS_DEFAULT_REGION` before running AWS examples. Examples read resources or sign URLs.

## Tests

With Tcl 9.1 and the dependencies on `TCLLIBPATH`:

```sh
make test TCLSH=tclsh9.1
```

Python 3 supplies local HTTP fixtures. Tests use fake credentials and do not
contact AWS. They check requests, result formats, and error handling.

## Install with ttrek

If you do not have the ttrek client, get it from [ttrek.sh](https://ttrek.sh).
Then install the package:

```sh
ttrek install pure-tcl-aws-dynamodb
```
