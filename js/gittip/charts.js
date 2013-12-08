Gittip.charts = {};


Gittip.charts.make = function(series) {
    // Takes an array of time series data.

    if (!series.length) {
        $('.chart-wrapper').remove();
        return;
    }

    // Sort the series in increasing date order
    series.sort(function(a,b) { return a.date > b.date ? 1 : -1 });

    // Gather charts.
    // ==============
    // We find charts based on the variable names from the first element in the
    // time series.

    var first = series[0];
    var charts = [];

    for (var varname in first) {
        var chart = $('#chart_'+varname);
        if (chart.length) {
            chart.varname = varname;
            charts.push(chart);
        }
    }

    var H = $('.chart').height();
    var nweeks = series.length;
    var w = 'calc(100% / '+ nweeks +')';

    $('.n-weeks').text(nweeks);


    // Compute maxes and scales.
    // =========================

    var maxes = [];
    var scales = [];

    for (var i=0, point; point = series[i]; i++) {
        for (var j=0, chart; chart = charts[j]; j++) {
            maxes[j] = Math.max(maxes[j] || 0, point[chart.varname]);
        }
    }

    for (var i=0, len=maxes.length; i < len; i++) {
        scales.push(Math.ceil(maxes[i] / 100) * 100);
    }


    // Draw weeks.
    // ===========

    function Week(i, j, max, N, y, title) {
        var create = function(x) { return document.createElement(x); };
        var week = $(create('div')).addClass('week');
        var shaded = $(create('div')).addClass('shaded');
        shaded.html( '<span class="y-label">'
                   + parseInt(y, 10)
                   + '</span>'
                    );
        week.append(shaded);
        week.attr({x: x, y: y});

        var xTick = $(create('span')).addClass('x-tick');
        xTick.text(i);
        xTick.attr('title', title);
        week.append(xTick);
        if (y === max) {
            maxes[j] = NaN; // only show one max flag
            week.addClass('flagged');
        }

        var y = parseFloat(y);
        var h = Math.ceil(y / N * H);
        shaded.css('height', h);
        week.css('width', w);
        return week;
    }

    for (var i=0, point; point = series[i]; i++) {
        var point = series[i];

        for (var j=0, chart; chart = charts[j]; j++) {

            var chart = charts[j];

            chart.append(Week( i
                             , j
                             , maxes[j]
                             , scales[j]
                             , point[charts[j].varname]
                             , point.date
                              ));
        }
    }

    // Wire up behaviors.
    // ==================

    function mouseover() {
        var x = $(this).attr('x');
        var y = $(this).attr('y');

        $(this).addClass('hover');
    }

    function mouseout() {
        $(this).removeClass('hover');
    }

    $('.week').click(function() {
        $(this).toggleClass('flagged');
        if ($(this).hasClass('flagged'))
            $(this).removeClass('hover');
    });
    $('.week').mouseover(mouseover);
    $('.week').mouseout(mouseout);
};
