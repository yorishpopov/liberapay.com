Liberapay.forms = {};

Liberapay.forms.clearInvalid = function($form) {
    $form.find('.invalid').removeClass('invalid');
};

Liberapay.forms.focusInvalid = function($form) {
    $form.find('.invalid').eq(0).focus();
};

Liberapay.forms.setInvalid = function($input, invalid) {
    $input.toggleClass('invalid', invalid);
};

Liberapay.forms.jsSubmit = function() {
    function submit(e) {
        e.preventDefault();
        var form = this.form || this;
        if (form.reportValidity && form.reportValidity() == false) return;
        var $form = $(form);
        var target = $form.attr('action');
        var js_only = target == 'javascript:';
        var data = $form.serializeArray();
        if (js_only) {
            // workaround for http://stackoverflow.com/q/11424037/2729778
            $form.find('input[type="checkbox"]').each(function () {
                var $input = $(this);
                if (!$input.prop('checked')) {
                    data.push({name: $input.attr('name'), value: 'off'});
                }
            });
        }
        var button = this.tagName == 'BUTTON' ? this : null;
        if (this.tagName == 'BUTTON') {
            data.push({name: this.name, value: this.value});
        }
        var $inputs = $form.find(':not(:disabled)');
        $inputs.prop('disabled', true);
        jQuery.ajax({
            url: js_only ? '' : target,
            type: 'POST',
            data: data,
            dataType: 'json',
            success: Liberapay.forms.success($form, $inputs, button),
            error: [
                function () { $inputs.prop('disabled', false); },
                Liberapay.error,
            ],
        });
    }
    $('.js-submit').submit(submit);
    $('.js-submit button').filter(':not([type]), [type="submit"]').click(submit);
};

Liberapay.forms.success = function($form, $inputs, button) { return function(data) {
    $inputs.prop('disabled', false).filter('[type=password]').val('');
    var on_success = $form.data('on-success');
    if (on_success && on_success.substr(0, 8) == 'fadeOut:') {
        var $e = $(button).parents(on_success.substr(8)).eq(0);
        return $e.fadeOut(null, $e.remove);
    }
    var msg = data && data.msg || $form.data('success');
    if (msg) {
        Liberapay.notification(msg, 'success');
    } else {
        window.location.href = window.location.href;
    }
}};
