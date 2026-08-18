import { colors } from 'graphs/common'

/**
 * Brand font family, read from the <meta name="brand-font"> tag set by Rails.
 * Falls back to the system font stack if the meta tag is absent.
 */
export const BRAND_FONT = (() => {
    const meta = document.querySelector('meta[name="brand-font"]')
    return meta ? meta.content : 'system-ui, sans-serif'
})()

/**
 * Shared chart configuration for ECharts across the application
 * Provides consistent styling, colors, and utility functions
 */

export const CHART_COLORS = {
    RED: '#DC2626',
    ORANGE: '#F97316',
    PURPLE: '#AE49EC',
    GREEN: '#00BC61',
    GRAY: '#A1A1AA'
}

export const CHART_COLOR_PALETTE = [
    CHART_COLORS.RED,
    CHART_COLORS.ORANGE,
    CHART_COLORS.PURPLE,
    CHART_COLORS.GREEN,
    CHART_COLORS.GRAY
]

export const TEXT_COLORS = {
    POSITIVE: 'text-[#00BC61]',
    NEGATIVE: 'text-[#F87171]',
    NEUTRAL: 'text-gray-400'
}

export const CHART_CONSTANTS = {
    ASR_SPARKLINE_TARGET: 'sparklineChart3',
    CHART_MAX_PADDING_FACTOR: 1.1, // Add 10% padding to max value for chart scaling
    DEFAULT_CHART_MAX: 100,
    DEFAULT_CHART_HEIGHT: 300,

    LINE_WIDTH_THIN: 1,
    LINE_WIDTH_DEFAULT: 2,

    FONT_SIZE_TINY: 9,
    FONT_SIZE_SMALL: 11,
    FONT_SIZE_DEFAULT: 12,
    FONT_SIZE_MEDIUM: 14,
    FONT_SIZE_LARGE: 16,
    FONT_SIZE_XLARGE: 36,

    OPACITY_SUBTLE: 0.2,
    OPACITY_MEDIUM: 0.45,
    OPACITY_STRONG: 0.6,

    GRID_PADDING_SMALL: '3%',
    GRID_PADDING_DEFAULT: '8%',
    GRID_PADDING_MEDIUM: '10%',
    GRID_PADDING_LARGE: '12%',
    GRID_PADDING_XLARGE: '15%'
}

/**
 * Standard tooltip configuration with glassmorphism effect
 * @returns {Object} ECharts tooltip configuration
 */
export const tooltipConfig = {
    backgroundColor: 'rgba(39, 39, 42, 0.6)',
    borderWidth: 0,
    textStyle: {
        color: '#FFFFFF',
        fontFamily: BRAND_FONT,
        fontSize: 12
    },
    padding: [8, 12],
    borderRadius: 12,
    shadowBlur: 10,
    shadowColor: 'rgba(0, 0, 0, 0.3)',
    shadowOffsetY: 2,
    extraCssText: '-webkit-backdrop-filter: blur(6px); backdrop-filter: blur(6px);'
}

/**
 * Base chart configuration with text styling
 * @param {Object} colors - Color theme object from graphs/common
 * @returns {Object} Base ECharts configuration
 */
export function baseChartConfig(colors) {
    return {
        textStyle: {
            color: colors.textColor,
            fontFamily: BRAND_FONT
        },
        title: {
            textStyle: { color: colors.textColor }
        }
    }
}

/**
 * Get color for gauge charts based on value thresholds
 * @param {number} value - Value between 0-100
 * @returns {string} Hex color code
 */
export function getGaugeColor(value) {
    if (value < 25) return '#71717A';
    if (value < 50) return '#EEF797';
    if (value < 75) return '#F89D53';
    return '#F87171';
}

/**
 * Get gauge chart configuration for ASR gauges
 * @param {number} successRate - Success rate value (0-100)
 * @param {Object} chartConfig - Base chart configuration
 * @param {string} name - Name of the gauge (e.g., 'Success Rate')
 * @returns {Object} ECharts gauge configuration
 */
export function getGaugeChartConfig(successRate, chartConfig, name = 'Success Rate') {
    return {
        ...chartConfig,
        backgroundColor: 'transparent',
        tooltip: {
            ...tooltipConfig,
            formatter: '{b}: {c}%'
        },
        series: [
            {
                name: name,
                type: 'gauge',
                startAngle: 180,
                endAngle: 0,
                center: ['50%', '75%'],
                radius: '100%',
                min: 0,
                max: 100,
                splitNumber: 8,
                axisLine: {
                    lineStyle: {
                        width: 6,
                        color: [
                            [0.25, '#71717A'],
                            [0.50, '#EEF797'],
                            [0.75, '#F89D53'],
                            [1, '#F87171']
                        ]
                    }
                },
                pointer: {
                    icon: 'path://M12.8,0.7l12,40.1H0.7L12.8,0.7z',
                    length: '12%',
                    width: 10,
                    offsetCenter: [0, '-60%'],
                    itemStyle: {
                        color: 'auto'
                    }
                },
                axisTick: {
                    length: 12,
                    lineStyle: {
                        color: 'auto',
                        width: 2
                    }
                },
                splitLine: {
                    length: 20,
                    lineStyle: {
                        color: 'auto',
                        width: 5
                    }
                },
                axisLabel: {
                    fontSize: 14,
                    distance: -50,
                    rotate: 'tangential',
                    fontFamily: BRAND_FONT,
                    formatter: function (value) {
                        if (value === 12.5) return '{low|Low}';
                        if (value === 37.5) return '{moderate|Moderate}';
                        if (value === 62.5) return '{high|High}';
                        if (value === 87.5) return '{extreme|Extreme}';
                        return '';
                    },
                    rich: {
                        low: {
                            color: '#71717A',
                        },
                        moderate: {
                            color: '#EEF797',
                        },
                        high: {
                            color: '#F89D53',
                        },
                        extreme: {
                            color: '#F87171',
                        }
                    }
                },
                title: {
                    offsetCenter: [0, '-10%'],
                    fontSize: 16,
                    fontFamily: BRAND_FONT,
                    color: chartConfig.textStyle.color
                },
                detail: {
                    fontSize: 30,
                    fontFamily: BRAND_FONT,
                    offsetCenter: [0, '-35%'],
                    valueAnimation: true,
                    formatter: function (value) {
                        // nothing measurable (nil rate, or ECharts coercing null to NaN) must not render as a false "0"
                        return Number.isFinite(value) ? Math.round(value) + '' : 'N/A';
                    },
                    color: 'inherit'
                },
                data: [
                    {
                        value: successRate,
                        name: name
                    }
                ]
            }
        ]
    };
}

/**
 * Convert hex color to rgba with specified alpha
 * @param {string} hex - Hex color code (e.g., '#DC2626')
 * @param {number} alpha - Alpha value between 0 and 1
 * @returns {string} RGBA color string
 */
export function hexToRgba(hex, alpha = 1) {
    const r = parseInt(hex.slice(1, 3), 16);
    const g = parseInt(hex.slice(3, 5), 16);
    const b = parseInt(hex.slice(5, 7), 16);
    return `rgba(${r}, ${g}, ${b}, ${alpha})`;
}

/**
 * Wrap text for radar chart labels to fit within space
 * @param {string} value - Text to wrap
 * @param {number} maxCharsPerLine - Maximum characters per line
 * @returns {string} Text with newline characters
 */
export function wrapText(value, maxCharsPerLine = 15) {
    if (value.length <= maxCharsPerLine) return value;

    const words = value.split(' ');
    let lines = [];
    let currentLine = '';

    words.forEach(word => {
        if ((currentLine + ' ' + word).trim().length <= maxCharsPerLine) {
            currentLine = (currentLine + ' ' + word).trim();
        } else {
            if (currentLine) lines.push(currentLine);
            currentLine = word;
        }
    });
    if (currentLine) lines.push(currentLine);

    return lines.join('\n');
}

/**
 * Standard error handler for chart initialization
 * @param {Object} chart - ECharts instance
 * @param {Object} chartConfig - Base chart configuration
 * @param {string} errorMessage - Error message to display
 * @param {Error} error - Optional error object for logging
 */
export function handleChartError(chart, chartConfig, errorMessage, error = null) {
    if (error) {
        console.error(`Chart Error: ${errorMessage}`, error);
    }

    chart.setOption({
        ...chartConfig,
        title: {
            text: errorMessage,
            left: 'center',
            top: 'center',
            textStyle: {
                color: colors.textColor,
                fontSize: 16
            }
        }
    });
}
