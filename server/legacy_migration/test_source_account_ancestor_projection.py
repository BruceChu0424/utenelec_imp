import copy
import unittest
import validate_source_completeness as verifier


def source_tree():
    return [dict(legacy_id='800',style_class_id='1',code='102',name='银行存款',parent_legacy='0'),
            dict(legacy_id='801',style_class_id='1',code='102',name='本地结算户',parent_legacy='800')]


def account():
    return dict(legacy_id='900',code='OLD-X',name='本地结算户',status='使用',style_legacy_id='801')


class SourceAccountAncestorTests(unittest.TestCase):
    def test_true_source_bank_ancestor_sets_bank_type(self):
        self.assertEqual(verifier.existing_account_projection(account(),source_tree()),('BANK',1))

    def test_child_code_alone_is_not_a_bank_root(self):
        styles=source_tree();styles[0].update(code='999',name='其他资产')
        self.assertEqual(verifier.existing_account_projection(account(),styles),('GENERAL',1))

    def test_non_account_chain_cannot_classify_bank(self):
        styles=source_tree();styles[1]['style_class_id']='4'
        self.assertEqual(verifier.existing_account_projection(account(),styles),('GENERAL',1))

    def test_ambiguous_real_roots_are_rejected(self):
        styles=source_tree();other=copy.deepcopy(styles[0]);other['legacy_id']='802';styles.append(other)
        with self.assertRaisesRegex(ValueError,'Ambiguous'):
            verifier.existing_account_projection(account(),styles)

    def test_missing_source_ancestor_is_rejected(self):
        with self.assertRaisesRegex(ValueError,'Missing'):
            verifier.existing_account_projection(account(),source_tree()[1:])

    def test_cyclic_source_parent_chain_is_rejected(self):
        styles=source_tree();styles[0]['parent_legacy']='801'
        with self.assertRaisesRegex(ValueError,'Cyclic'):
            verifier.existing_account_projection(account(),styles)

    def test_existing_specific_cash_rule_keeps_precedence(self):
        row=account();row['name']='备用现金'
        self.assertEqual(verifier.existing_account_projection(row,source_tree()),('CASH',1))

    def test_general_account_spelling_variants_keep_precedence(self):
        for name in ('一般账户','一般帐户'):
            row=account();row['name']=name
            with self.subTest(name=name):
                self.assertEqual(verifier.existing_account_projection(row,source_tree()),('GENERAL',1))

    def test_new_identity_still_requires_explicit_review(self):
        with self.assertRaisesRegex(ValueError,'New or removed'):
            verifier.validate_reviewed_accounts([account()],{'reviewed_accounts':[]},source_tree())

    def test_reviewed_identity_hash_and_type_remain_required(self):
        row=account();profile={'reviewed_accounts':[dict(legacy_id=900,
            code_name_status_sha256=verifier.account_fingerprint(row),account_type='BANK',currency_legacy_id=1)]}
        self.assertEqual(verifier.validate_reviewed_accounts([row],profile,source_tree()),1)
        profile['reviewed_accounts'][0]['account_type']='GENERAL'
        with self.assertRaisesRegex(ValueError,'projection'):
            verifier.validate_reviewed_accounts([row],profile,source_tree())


if __name__=='__main__':unittest.main()
