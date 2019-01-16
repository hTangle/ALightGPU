#pragma once
#include "root.h"
#include "ray.h"
#include <fstream>

void Render();

inline void Resize(int width, int height) {
	glutReshapeWindow(ImageWidth, ImageHeight);
}

inline void WindowsUpdate()
{
	glClear(GL_COLOR_BUFFER_BIT);
	glDrawPixels(ImageWidth, ImageHeight, GL_RGBA, GL_UNSIGNED_BYTE, PixelData);
	glutSwapBuffers();
	glFlush();
}

inline void TimerProc(int id)
{
	glutPostRedisplay();
	glutTimerFunc(1, TimerProc, 1);//需要在函数中再调用一次，才能保证循环  
}

inline void InitWindow(int argc, char** argv, unsigned int mode, int x_position, int y_position, int width, int heigth, const char * title)
{
	glutInit(&argc, argv);
	glutInitDisplayMode(mode);
	glutInitWindowPosition(x_position, y_position);
	glutInitWindowSize(width, heigth);
	glutCreateWindow(title);
	glClearColor(1.0, 0.0, 1.0, 1.0);
	glMatrixMode(GL_PROJECTION);
	gluOrtho2D(0.0, 200.0, 0.0, 150.0);

	glutDisplayFunc(WindowsUpdate);
	glutTimerFunc(1, TimerProc, 1);
	glutReshapeFunc(Resize);
	glutMainLoop();
}

inline void SetPixel(const int x, const int y, Vec3* c)
{
	const auto i = ImageWidth * 4 * y + x * 4;
	//Changes[width * y + x]++;
	PixelData[i] = c->r() * 255;
	PixelData[i + 1] = c->g() * 255;
	PixelData[i + 2] = c->b() * 255;
	PixelData[i + 3] = static_cast<GLbyte>(255);
}

inline void Savepic()
{
	std::ofstream outf;
	outf.open("/Output/abc.ppm");
	outf << "P3\n" << ImageWidth << " " << ImageHeight << "\n255\n";
	for (auto h = ImageHeight - 1; h >= 0; h--)
	{
		for (int i = 0; i < rgbwidth; i += 3)
		{
			outf << PixelData[h *(rgbwidth)+(i + 0)] << " " <<
				PixelData[h *(rgbwidth)+(i + 1)] << " " <<
				PixelData[h *(rgbwidth)+(i + 2)] << " \n";
		}
	}
	outf.close();
	std::cout << "finished" << std::endl;
}

inline void ShowProgress(int num, int sum)
{
	system("cls");
	std::cout << (sum - num) * 100 / sum << "%" << std::endl;
}

