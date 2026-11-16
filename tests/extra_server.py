from support import Fixture, run, verify_signature
import json


class Handler(Fixture):
    def route(self, body):
        assert verify_signature(self, body) == "dynamodb"
        data = json.loads(body)
        action = self.headers["X-Amz-Target"].split(".")[-1]
        if action == "CreateTable":
            assert data["BillingMode"] == "PROVISIONED"
            assert data["ProvisionedThroughput"] == {"ReadCapacityUnits": 1, "WriteCapacityUnits": 2}
            assert data["GlobalSecondaryIndexes"][0]["KeySchema"] == [{"AttributeName": "other", "KeyType": "HASH"}]
            result = {}
        elif action == "DeleteTable":
            result = {}
        elif action == "ListTables":
            result = {"TableNames": ["two"]} if "ExclusiveStartTableName" in data else {"TableNames": ["one"], "LastEvaluatedTableName": "one"}
        elif action == "Scan":
            result = {"Items": [{"id": {"S": "two"}}]} if "ExclusiveStartKey" in data else {"Items": [], "LastEvaluatedKey": {"id": {"S": "one"}}}
        elif action == "UpdateItem":
            assert data["UpdateExpression"] == "SET n = :n"
            assert data["ExpressionAttributeValues"][":n"] == {"N": "123456789012345678901234567890.12345678"}
            result = {"Attributes": {"n": data["ExpressionAttributeValues"][":n"]}}
        elif action == "PutItem":
            expected = {"nested": {"M": {"list": {"L": [{"BOOL": False}, {"NULL": True}, {"B": "AP8="}]}}}, "n": {"N": "123456789012345678901234567890.12345678"}, "set": {"SS": ["one", "two"]}}
            assert data["Item"] == expected
            self.server.item = expected
            result = {}
        else:
            assert action == "GetItem"
            result = {"Item": self.server.item}
        self.reply(200, result)


if __name__ == "__main__":
    run(Handler, "extra.test")
