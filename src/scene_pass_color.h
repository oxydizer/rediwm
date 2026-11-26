// Client samples are electrically premultiplied. Decode straight RGB first,
// then convert primaries and premultiply in the destination blend space.
#pragma once
#define GLSL_BT2020_TO_BT709 "mat3(1.660491,-.124550,-.018151,-.587641,1.132900,-.100579,-.072850,-.008349,1.118730)"
// A continuous shoulder with unit slope at 0.75, asymptotic to SDR white.
// Scale all three channels together to keep highlight hue.
#define GLSL_SDR_KNEE \
    "vec3 knee(vec3 c){float m=max(c.r,max(c.g,c.b)); if(m<=.75)return c;" \
    "return c*((1.-.0625/(m-.5))/m);}"
#define GLSL_CLIENT_COLOR \
    "\n#ifdef CLIENT_COLOR\n" GLSL_SDR_KNEE \
    "uniform vec4 source_color;" /* transfer, BT.2020 primaries, PQ scale, SDR destination */ \
    "vec4 client(vec4 pixel){if(pixel.a<=0.)return vec4(0.);vec3 c=pixel.rgb/pixel.a;" \
    "if(source_color.x==2.){" /* ST 2084 EOTF; PQ represents absolute nits */ \
    "vec3 p=pow(clamp(c,0.,1.),vec3(1./78.84375));" \
    "c=pow(max(p-.8359375,0.)/(18.8515625-18.6875*p),vec3(1./.1593017578125))*source_color.z;" \
    "}else if(source_color.x==1.){" /* IEC 61966-2-1 compound power 2.4 */ \
    "c=mix(c/12.92,pow(max((c+.055)/1.055,0.),vec3(2.4)),step(vec3(.04045),c));" \
    "}else if(source_color.x!=4.)c=pow(max(c,0.),vec3(2.2));" /* extended linear passes through */ \
    "if(source_color.w>.5){" \
    "if(source_color.y>.5)c=" GLSL_BT2020_TO_BT709 "*c;" \
    "if(source_color.x==2.||source_color.x==4.)c=knee(c);" \
    "c=clamp(c,0.,1.);" \
    "\n#ifdef LINEAR\n c=" GLSL_BT709_TO_BT2020 "*c;\n#else\n c=pow(c,vec3(1./2.2));\n#endif\n" \
    "}else if(source_color.y<.5)c=" GLSL_BT709_TO_BT2020 "*c;" \
    "return vec4(c*pixel.a,pixel.a);}" \
    "\n#define SAMPLE(c) client(c)\n#else\n#define SAMPLE(c) LIN(c)\n#endif\n"
